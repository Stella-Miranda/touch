#!/bin/sh
# Usage: share/make_qr.sh https://your-site-url
# Regenerates share/qr.png for the given link.
python3 -c "import qrcode,sys; qrcode.make(sys.argv[1]).save('$(dirname "$0")/qr.png')" "$1" && echo "Saved $(dirname "$0")/qr.png for $1"
