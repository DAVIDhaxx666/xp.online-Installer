#!/bin/bash
 
# --- 1. DYNAMIC SYSTEM AUDIT ---
TOTAL_RAM_MB=$(free -m | awk '/^Mem:/{print $2}')
SYSTEM_RESERVE_MB=4096
VM_RAM_MB=512
AVAILABLE_MB=$((TOTAL_RAM_MB - SYSTEM_RESERVE_MB))
MAX_VMS=$((AVAILABLE_MB / VM_RAM_MB))
CPU_THREADS=$(nproc)
SAFE_CPU_LIMIT=$((CPU_THREADS * 3))

echo "--- 2025 VNC Farm Report ---"
echo "Total RAM: ${TOTAL_RAM_MB}MB | System Reserve: 4GB"
echo "Max VM Slots: $MAX_VMS | CPU Threads: $CPU_THREADS"
[ "$MAX_VMS" -lt 1 ] && { echo "Error: Insufficient RAM."; exit 1; }

# --- 2. CONFIGURATION ---
IMAGE_URL="https://github.com/DAVIDhaxx666/xp.online-Installer/releases/download/release-1.0/winxp.img"
NOVNC_DIR="/opt/novnc"
FLASK_DIR="/opt/vnc_farm"
XP_IMAGE="winxp.img"
USER_NAME=$(whoami)

# --- 3. SYSTEM INSTALLATION (Apt-Only) ---
sudo apt update
sudo apt install -y qemu-system-x86 websockify nginx git curl python3-flask python3-websockify python3-pip

# --- 4. ASSET SETUP ---
sudo mkdir -p $FLASK_DIR $NOVNC_DIR
if [ ! -d "$NOVNC_DIR/.git" ]; then
    echo "Cloning noVNC from GitHub..."
    sudo git clone github.com $NOVNC_DIR
    sudo ln -sf $NOVNC_DIR/vnc.html $NOVNC_DIR/index.html
fi

if [ ! -f "$FLASK_DIR/$XP_IMAGE" ]; then
    echo "Downloading WinXP image from GitHub..."
    sudo curl -L -o "$FLASK_DIR/$XP_IMAGE" "$IMAGE_URL"
    sudo chown $USER_NAME:$USER_NAME "$FLASK_DIR/$XP_IMAGE"
fi

# --- 5. NGINX GATEWAY ---
sudo tee /etc/nginx/sites-available/vnc_farm <<EOF
server {
    listen 8000;
    location /launch { proxy_pass http://127.0.0.1:5000; }
    location /vnc/ { alias $NOVNC_DIR/; index vnc.html; }
    location ~ ^/ws/([6-9][0-9][0-9][0-9])$ {
        proxy_pass http://127.0.0.1:\$1;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "Upgrade";
        proxy_read_timeout 300s;
    }
}
EOF
sudo ln -sf /etc/nginx/sites-available/vnc_farm /etc/nginx/sites-enabled/
sudo rm -f /etc/nginx/sites-enabled/default
sudo systemctl restart nginx

# --- 6. FLASK QUEUE MANAGER ---
sudo tee $FLASK_DIR/app.py <<EOF
import subprocess, uuid, time, socket, json
from threading import Semaphore, Thread, Lock
from flask import Flask, redirect, request

app = Flask(__name__)
MAX_VMS = $MAX_VMS
available_slots = list(range(1, MAX_VMS + 1))
slot_lock = Lock()
vm_semaphore = Semaphore(MAX_VMS)
active_sessions = {}

def is_vnc_active(slot_id):
    try:
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        s.settimeout(1)
        s.connect(f"/tmp/qmp-{slot_id}.sock")
        s.recv(1024); s.send(b'{"execute":"qmp_capabilities"}\\n'); s.recv(1024)
        s.send(b'{"execute":"query-vnc"}\\n')
        res = json.loads(s.recv(4096))
        s.close()
        return len(res['return']['clients']) > 0
    except: return False

def vm_worker(user_id):
    vm_semaphore.acquire()
    with slot_lock: slot_id = available_slots.pop(0)
    active_sessions[user_id] = slot_id
    qemu_proc = subprocess.Popen([
        "qemu-system-x86_64", "-accel", "kvm", "-m", "512",
        "-vnc", f":{slot_id}", "-qmp", f"unix:/tmp/qmp-{slot_id}.sock,server,nowait",
        "-hda", "$FLASK_DIR/$XP_IMAGE", "-usb", "-device", "usb-tablet", "-net", "nic,model=rtl8139", "-net", "user", "-display", "none"
    ])
    ws_proc = subprocess.Popen(["websockify", str(6000+slot_id), f"localhost:{5900+slot_id}"])
    while qemu_proc.poll() is None:
        time.sleep(30)
        if not is_vnc_active(slot_id):
            qemu_proc.terminate(); break
    ws_proc.terminate()
    with slot_lock:
        available_slots.append(slot_id); available_slots.sort(); active_sessions.pop(user_id, None)
    vm_semaphore.release()

@app.route('/launch')
def launch():
    user_id = request.args.get('uid', str(uuid.uuid4()))
    if user_id in active_sessions:
        return redirect(f"/vnc/vnc.html?autoconnect=true&path=ws/{6000+active_sessions[user_id]}")
    Thread(target=vm_worker, args=(user_id,)).start()
    return f"Preparing VM... Slot assigned automatically. <script>setTimeout(()=>location.href='/launch?uid={user_id}', 5000)</script>"

if __name__ == '__main__':
    app.run(port=5000)
EOF

# --- 7. SERVICE AUTORUN ---
sudo tee /etc/systemd/system/vnc_farm.service <<EOF
[Unit]
Description=VNC Farm Queue Service
After=network.target
[Service]
User=$USER_NAME
WorkingDirectory=$FLASK_DIR
ExecStart=/usr/bin/python3 $FLASK_DIR/app.py
Restart=always
[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable --now nginx vnc_farm

# --- 8. TUNNEL ---
echo "Setup complete. Launching TryCloudflare..."
cloudflared tunnel --url http://localhost:8000
