#!/bin/bash
echo "Removing old pacman package versions from the cache, but keeping the 2 most recent."
paccache -rk2
echo ""
echo "Removing all pacman packages from the cache that are no longer installed."
paccache -ruk0
echo ""

# Only clean paru cache if it exists
paru_cache="/home/$user/.cache/paru"
if [ -d "$paru_cache" ]; then
    echo "Removing old paru package versions from the cache, but keeping the 2 most recent."
    paccache -rk2 -c "$paru_cache"/*
    echo ""
    echo "Removing all paru packages from the cache that are no longer installed."
    paccache -ruk0 -c "$paru_cache"/*
fi