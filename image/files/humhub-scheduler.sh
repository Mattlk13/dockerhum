#!/bin/bash

sleep 5

while true; do

    output=$(/app/yii queue/info 2>&1)

    if [[ "$output" != *'yii\\db\\Exception'* ]]; then
        echo "Cron: Database connection successful. Initiated..."
        break
    else
        echo "Cron: Database not configured and initialized. Waiting..."
        sleep 30
    fi
done

while true; do

    /app/yii cron/run
    sleep 60

done
