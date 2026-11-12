qing@spider-qsont:~/bot4cj $ sudo cp /boot/firmware/config.txt /boot/firmware/config.txt.bak && \
sudo sed -i 's/^[[:space:]]*camera_auto_detect=.*/camera_auto_detect=0/' /boot/firmware/config.txt && \
grep -q '^camera_auto_detect=' /boot/firmware/config.txt || echo 'camera_auto_detect=0' | sudo tee -a /boot/firmware/config.txt >/dev/null

sudo sed -i 's/^[[:space:]]*dtparam=i2c_vc=on/#dtparam=i2c_vc=on/' /boot/firmware/config.txt

grep -q '^dtoverlay=i2c0,pins_44_45' /boot/firmware/config.txt || \
echo 'dtoverlay=i2c0,pins_44_45' | sudo tee -a /boot/firmware/config.txt

echo "===== 当前相关配置 ====="
grep -E 'camera_auto_detect|i2c_arm|i2c_vc|dtoverlay=i2c0' /boot/firmware/config.txt

echo "===== 3秒后重启 ====="
sleep 3
sudo reboot