#!/bin/bash

#---------------------------------------------
#
# This script starts the Queue Listener. 
# Before that, it checks whether the database connection and the HumHub setup have been completed. 
#
#---------------------------------------------


sleep 5

while true; do

    output=$(/app/yii queue/info 2>&1)

    if [[ "$output" != *'yii\\db\\Exception'* ]]; then
        echo "Worker: Database connection successful. Initiated..."
        break
    else
        echo "Worker: Database not configured and initialized. Waiting..."
        sleep 30
    fi
done

/app/yii queue/listen --verbose=1 --color=0
