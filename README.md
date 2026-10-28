# webcam_to_prusa_connect
This script for linux with systemd uses curl to send pictures from webcams to prusa connect. It pulls each snapshot from [go2rtc](https://github.com/AlexxIT/go2rtc), which owns the cameras, so the same camera can also be streamed live (for example to Home Assistant). Frames live only in a RAM-backed temp directory, never on the SD card.
It is tested for Raspberry Pi OS Lite (Trixie).

## Usage

### Install needed tools
If not present install git for cloning this repository. Snapshots come from a go2rtc instance that serves each camera's latest frame at `/api/frame.jpeg`; set that up first.

    sudo apt install git curl

### Clone the repository

    git clone https://github.com/sefose/webcam_to_prusa_connect.git

### Create settings.conf
To edit the script you can use nano and close with ctrl + x and save your changes

    cd webcam_to_prusa_connect/
    nano settings.conf

The following section needs to be added according to your setup. Each entry in each line corrosponds to one camera at the position in the entry. You can use one or multiple cameras.

    CAMERA_NAMES=("cam1" "cam2")
    CAMERA_SNAPSHOT_URLS=("http://127.0.0.1:1984/api/frame.jpeg?src=cam1" "http://127.0.0.1:1984/api/frame.jpeg?src=cam2")
    TOKENS=("XXXXX" "XXXXX")

#### CAMERA_NAMES
You can choose the names freely - they appear in the log of the script.

#### CAMERA_SNAPSHOT_URLS
The go2rtc snapshot URL for each camera. Device, resolution and focus are configured in go2rtc, not here. Keep the camera's go2rtc stream open with go2rtc's `preload:` setting: a camera opened just for one snapshot returns a poorly exposed, wrongly framed first frame.

#### TOKENS
Go to the camera section of your printer in prusa connect and click "Add new another camera"
This generates the needed Token.

### Install service
For the script to start with the machine, we use an systemd service.
The script "create_systemd_service.sh" creates a service.

    sudo ./create_systemd_service.sh

more information: https://tecadmin.net/run-shell-script-as-systemd-service/

Now the script should send pictures to prusa connect

## Sources
Thanks Djaesthetic for this solution to start with: https://www.reddit.com/r/prusa3d/comments/1971673/streaming_a_webcam_via_rtsp_to_prusa_connect/

To save ressources on the pi and make things less complicated I replaced the rtsp stream to get the picture from the cam directly.

Thanks jtee3d for sharing his work using multiple devices with one script! https://github.com/jtee3d/prusa_connect_rtsp
