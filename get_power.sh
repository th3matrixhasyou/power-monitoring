#!/bin/bash
TARGET_DIR="/home/neo/monitoring/textfile_data"
FINAL_FILE="$TARGET_DIR/ipmi_power.prom"
TMP_FILE="$FINAL_FILE.tmp"
PROM_YML="/home/neo/monitoring/prometheus/prometheus.yml"

mkdir -p "$TARGET_DIR"
echo "# HELP ipmi_custom_power_watts Total System Power" > "$TMP_FILE"
echo "# TYPE ipmi_custom_power_watts gauge" >> "$TMP_FILE"

/usr/bin/docker exec ipmi-exporter cat /etc/ipmi_exporter/ipmi.yml 2>/dev/null | \
awk -F'[" ]+' '
/ibmc_/ {ip=$2; gsub("ibmc_","",ip); gsub(":","",ip); gsub("_",".",ip); curr_ip=ip}
/user:/ {curr_u=$3}
/pass:/ {print curr_ip, curr_u, $3}' | \
while read -r IP USER PASS; do
    (
        # 1. Пробуем DCMI (Точно работает для Huawei, например g6-680)
        WATTS=$(ipmitool -I lanplus -C 17 -H "$IP" -U "$USER" -P "$PASS" dcmi power reading 2>/dev/null | grep -i 'Instantaneous power reading' | awk -F':' '{gsub(/[^0-9.]/,"",$2); print $2}')
        
        # 2. Если DCMI вернул пустоту ИЛИ 0 (Lenovo XCC) -> ищем в SDR ЛЮБОЙ сенсор мощности строго больше нуля
        if [ -z "$WATTS" ] || [ "$WATTS" == "0" ]; then
            WATTS=$(ipmitool -I lanplus -C 17 -H "$IP" -U "$USER" -P "$PASS" sdr list full 2>/dev/null | grep -iE 'power|pwr|watt' | awk -F'|' '{val=$2; gsub(/[^0-9.]/,"",val); if(val+0 > 0) {print val; exit}}')
        fi
        
        # Записываем метрику в файл ТОЛЬКО если мы нашли реальные Ватты (не 0 и не пустоту)
        if [ -n "$WATTS" ] && [ "$WATTS" != "0" ]; then
            LABELS_LINE=$(grep -A1 "\['$IP'\]" "$PROM_YML" | tail -n 1)
            HOST=$(echo "$LABELS_LINE" | sed -nE "s/.*hostname:[ \t]*'([^']+)'.*/\1/p")
            RACK=$(echo "$LABELS_LINE" | sed -nE "s/.*rack:[ \t]*'([^']+)'.*/\1/p")
            
            if [ -n "$HOST" ] && [ -n "$RACK" ]; then
                echo "ipmi_custom_power_watts{instance=\"$IP\", hostname=\"$HOST\", rack=\"$RACK\"} $WATTS" >> "$TMP_FILE.$IP"
            fi
        fi
    ) &
done
wait

cat "$TMP_FILE".* 2>/dev/null >> "$TMP_FILE"
rm -f "$TMP_FILE".*
chown neo:neo "$FINAL_FILE" 2>/dev/null
mv "$TMP_FILE" "$FINAL_FILE"
