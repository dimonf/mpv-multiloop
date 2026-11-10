#!/usr/bin/bash
#
# Cut a fragment of a video with the minimal possible re-encoding. 
# If the new start point is not a key frame it reencodes the video 
# from that point until the frame before a new keyframe. The remaining
# part is copied as passthrough and both fragments are concatenated
#
# In order to make the video streams compatible we use the same codec
# and bitrate. This works fine with h264. No idea about other codecs

if [ "$#" -ne 3 ]; then
  echo "Usage: $0 <input file> <starting position> <end position>"
  exit 1
fi

FILE=$1
START=$2
END=$3

size="$(ffmpeg -hide_banner -i "$FILE" -f null -c copy -map 0:v:0 - |& awk -F'[:|kB]' '/video:/ {print $2}')"
codec="$(ffprobe -hide_banner -loglevel error -select_streams v:0 -show_entries stream=codec_name -of default=nk=1:nw=1 "$FILE")"
duration="$(ffprobe -hide_banner -loglevel error -select_streams v:0 -show_entries format=duration -of default=nk=1:nw=1 "$FILE")"
bitrate="$(bc -l <<< "$size"/"$duration"*8.192)"

echo "Finding keyframes in $FILE"
KEYFRAMES=$(ffprobe -hide_banner -loglevel error -select_streams v -show_frames -show_entries "frame=pkt_pts_time,pict_type" -of "json=compact=1" $FILE | jq '.frames | .[] | select(.pict_type == "I") | .pkt_pts_time ' | tr -d '"')
declare -a KEYFRAMES_PTS
for pts in $KEYFRAMES; do KEYFRAMES_PTS+=($pts); done

if [[ " ${KEYFRAMES_PTS[*]} " =~ " ${START} " ]]; then
  echo "$START is a keyframe doint a keyframe cut"
  ffmpeg -hide_banner -loglevel error -ss $START -i $FILE -t $END -c:v copy -map '0:0' -map '0:1' -map_metadata 0 -movflags use_metadata_tags -ignore_unknown -f mp4 -y $FILE-cut.mp4
  exit 0
fi

echo "$START is not a keyframe"
temp_dir=$(mktemp -d)

# bash does not support floating point comparison so we go with bc
for i in "${!KEYFRAMES_PTS[@]}"; do
  echo pts[$i]=${KEYFRAMES_PTS[$i]} >> $temp_dir/get_next_keyframe_and_end.bc
done
echo "for (i = 0;i < ${#KEYFRAMES_PTS[@]};++i) { if (pts[i] < $START) { continue } else { pts[i]; pts[i] - 0.000001; break } }" >> $temp_dir/get_next_keyframe_and_end.bc
read -r NEXT_KEY_FRAME ENDPOS <<<$(cat $temp_dir/get_next_keyframe_and_end.bc | bc -l | tr "\n" " ")

echo "Re-encoding from $START until the last frame before a new keyframe ($ENDPOS)"
ffmpeg -hide_banner -loglevel error -i $FILE -ss $START -to $ENDPOS -c:a copy -map '0:0' -map '0:1' -map_metadata 0 -movflags use_metadata_tags -ignore_unknown -c:v "$codec" -b:v "$bitrate"k -f mp4 -y $temp_dir/output0.mp4
echo "Extracting video from the next keyframe ($NEXT_KEY_FRAME) to the end $END"
ffmpeg -hide_banner -loglevel error -ss $NEXT_KEY_FRAME -i $FILE -to $END -c:v copy -map '0:0' -map '0:1' -map_metadata 0 -movflags use_metadata_tags -ignore_unknown -f mp4 -y $temp_dir/output1.mp4
echo "file 'output0.mp4'" > $temp_dir/filelist.txt
echo "file 'output1.mp4'" >> $temp_dir/filelist.txt
echo "Merging files..."
ffmpeg -hide_banner -loglevel error -f concat -i $temp_dir/filelist.txt -c copy  $FILE-cut.mp4
rm -rf $temp_dir
