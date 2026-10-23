#!/bin/bash

while true; do
    # 1. Wait quietly until the Friends List appears (checks every 1 second)
    while ! wmctrl -l | grep -q "Friends List"; do
        sleep 1
    done

    # 2. Window detected! Wait a fraction of a second for it to draw, then move it
    sleep 0.2
    wmctrl -r "Friends List" -e 0,3178,1947,-1,-1

    # 3. Wait until you CLOSE the Friends List before starting over.
    # (If we don't do this, the script will rapidly fire the move command forever)
    while wmctrl -l | grep -q "Friends List"; do
        sleep 2
    done
done
