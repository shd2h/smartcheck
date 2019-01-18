#!/bin/bash
# smartcheck.sh - collects smart info on about each drive, and stores it in local log files for later review.
# requires awk + tail
# v0.1.0 - basic info gathering and storing of data per drive works.
# v0.2.0 - rewrite! changed around the logging, made it more robust, and laid the groundwork for future expansion.
# v0.2.1 - logging of smart values converted to csv. included critical smart value increase checks.
# v0.2.2 - added checking against threshold values, and updated the summary
# v0.3.0 - almost feature complete, log management + error checking still to come
# v0.3.1 - minor bugfix (fix typos)
# v0.3.2 - fix versioning, add basic log management for summary log.
#
#
# This script is designed to rip through the output of smartctl, extract the most useful info and give the end user
# a nice summary of the health of their drive. It also keeps a copy of the full smart output every time it was run,
# and tracks the most critical smart values (thanks backblaze -
# https://www.backblaze.com/blog/what-smart-stats-indicate-hard-drive-failures/ ) to hopefully give more tools to
# keep tabs on your drives. Note: I don't track 187/188 because none of my drives report them.
# 
# The good/bad overall drive status check is calculated by performing the same evaluation openmediavault does in its
# smart GUI, so if the script says that the drive overall is "bad", OMV should agree.
#
# By default it writes all output and logs to ~/smartmonitoring under the current users home directory. Summary logs
# are located inside this directory, as are the drives csv files tracking critical values, and the individual full outputs
# are located under sub-directories named by serial #. The script should be able to cope with device assignments changing
# if you add/remove drives, and will continue to track the drives stats regardless.
#
# Finally: This script isn't a magic box that will tell you if/when a drive will fail. It is just another tool and drives
# may fail regardless of how healthy they appear via smart statistics.
#
# Depends on: smartctl, grep, awk.


## USER CONFIGURABLE SETTINGS BLOCK

outputdir=~/smartmonitoring # change the output directory for the log files.

## END USER CONFIGURABLE SETTINGS BLOCK

timestamp=$(date +%Y%m%dT%H%M%S)
timestamp_date=$(date +%Y%m%d)

# test + create our work directory in the users home dir.
if [[ ! -e $outputdir ]]; then
   mkdir -p $outputdir
fi

# test for summary log dir, and create if needed. Otherwise move old summary log(s) to this dir.
if [[ ! -e $outputdir/summary ]]; then
   mkdir -p $outputdir/summary
else
   mv *_summary.log $outputdir/summary
fi

# initialise the summary log
{
   echo "===================="
   date
   echo " "
} > "$outputdir"/"$timestamp"_summary.log


# loop through all drives individually
for drive in /dev/sd[a-z] /dev/sd[a-z][a-z]; do

   # first check if there actually is a drive there, if not then skip everything else
   if [[ ! -e $drive ]]; then continue ; fi

   # record the smart info from each drive that responded, then do a quick check to see if they offer smart reporting
   smartinfo=$(smartctl -a $drive)
   smartenabled=$(echo "$smartinfo" | grep 'SMART overall' | awk '{print $6}')

   # skip the ones that don't offer smart reporting.
   if [[ -z $smartenabled ]]; then continue; fi

   # gather serial if smart is enabled
   driveserial=$(echo "$smartinfo" | grep 'Serial Number: ' | awk '{print $3}')


   # chop out the smart attributes segment from the full smart output
   smartvalues=$(echo "$smartinfo" | awk '!NF{f=0} /Raw_Read_Error_Rate/ {f=1} f')
   # build arrays from the smart attibutes. One array for each type of values; the variable names, their current values, their worst values, their threshold values.
   namearr=()
   currentarr=()
   worstarr=()
   thresharr=()
   while IFS= read -r line ; do
      n="$(echo $line | awk '{print $2}')"
      c="$(echo $line | awk '{print $4}')"
      w="$(echo $line | awk '{print $5}')"
      t="$(echo $line | awk '{print $6}')"
      namearr+=("$n")
      currentarr+=("$c")
      worstarr+=("$w")
      thresharr+=("$t")
   done <<< "$smartvalues"

   #Set the drive state to "good". If nothing else fails it will stay this way.
   overalldrivestate="Good"
   drivestateinfo=()

   # check if any of the smart attributes have ever been bad
   i=0
   # start to loop through array of all worst values
   for var in "${worstarr[@]}" ; do
      # compare the worst value to the corresponding threshold value. If it fails, then we overwrite the good state, update the state info, and break out of the loop (no point testing all the values)
      if [ "$var" -le "${thresharr[$i]}" ] ; then
         overalldrivestate="Warn"
		 drivestateinfo+=(" Disk attribute(s) have previously dipped below threshold.")
		 break
      fi
   i=$((i+1))
   done

   # check if any of the attributes are currently bad
   i=0
   # start to loop through array of all current values
   for var in "${currentarr[@]}" ; do
      # compare the current value to the corresponding threshold value. If it fails, then we overwrite the good state, update the state info, and break out of the loop (no point testing all the values)
      if [ "$var" -le "${thresharr[$i]}" ] ; then
         overalldrivestate="Bad"
		 drivestateinfo+=(" Disk attribute(s) are currently below threshold")
		 break
      fi
   i=$((i+1))
   done


   # get the smart "critical" values, we do this separately so that we don't care if the array changes size (different drives often report different #s of attributes)
   smart_5=$(echo "$smartinfo" | grep "5 Reallocated_Sector_Ct" | awk '{print $10}')
   smart_197=$(echo "$smartinfo" | grep "197 Current_Pending_Sector" | awk '{print $10}')
   smart_198=$(echo "$smartinfo" | grep "198 Offline_Uncorrectable" | awk '{print $10}')

   # check if any of the criticals are above 0, if so print error and update the state info.
   if [[ $smart_5 -gt 0 ||  $smart_197 -gt 0 ||  $smart_198 -gt 0 ]] ; then
      overalldrivestate="Bad"
      drivestateinfo+=(" Disk critical attribute(s) are above zero")
   fi

   # create an array with the current smart critical values
   smartcva=("$timestamp_date" "$smart_5" "$smart_197" "$smart_198")

   # test + create output dir for our drive if needed
   if [[ ! -e $outputdir/$driveserial ]]; then
      mkdir -p $outputdir/$driveserial
   fi

   # test + create our output csv with the drive smart values if needed; this will store a record of these values, and gives us our history
   if [[ ! -e $outputdir/$driveserial/smarthistory.csv ]]; then
      # fill the csv headers for an empty file
      echo "Timestamp,Reallocated_Sector_Ct,Current_Pending_Sector,Offline_Uncorrectable" > $outputdir/$driveserial/smarthistory.csv
   else
      # if we already have a file, pull last run values from it and store them into an array
      IFS=","
      lastrunsmaartcva=($(tail -1 $outputdir/$driveserial/smarthistory.csv))
      csvheadera=(Timestamp Reallocated_Sector_Ct Current_Pending_Sector Offline_Uncorrectable)
      smartvarsummary=()
      # compare the old values to the new ones to see if things are getting worse
      i=0
      # start to loop thru the current values array, starting in 1st position (to skip the timestamp) and reading next 3 values
      for var in "${smartcva[@]:1:3}" ; do
         i=$((i+1))
         # compare the new value to the value in our old array, store results in summary array for later use
         if [ "$var" -gt "${lastrunsmaartcva[$i]}" ] ; then
            smartvarsummary+=(" ${csvheadera[$i]} increased from ${lastrunsmaartcva[$i]} to $var")
         fi
      done
   fi
   # write the current values out to csv
   printf '%s\n' ${smartcva[@]} | paste -sd ',' >> $outputdir/$driveserial/smarthistory.csv


   # test + create dir for our drive's full logs if needed
   if [[ ! -e $outputdir/$driveserial/full_log ]]; then
      mkdir -p $outputdir/$driveserial/full_log
   fi

   # store complete smartctl -a output into a log file
   echo "$smartinfo" > "$outputdir"/"$driveserial"/full_log/"$timestamp"_smartinfo.log

   # add current drive results to summary log; print serial + overall state, then print the arrays containing additional state info and the smart variable summary if not empty.
   {
      echo "-----"
      echo "$driveserial" - "$overalldrivestate"
	  echo "-----"
	  [[ ${drivestateinfo[@]} ]] && printf '%s\n' "${drivestateinfo[@]}"
      [[ ${smartvarsummary[@]} ]] && printf '%s\n' "${smartvarsummary[@]}"
	  echo " "
   } >> "$outputdir"/"$timestamp"_summary.log
done

# print the summary to screen
echo "$(cat "$outputdir"/"$timestamp"_summary.log)"
