#!/bin/bash

PROM_FILE="prometheus/prometheus.yml"
IPMI_ENC="ipmi/ipmi.yml.enc"
IPMI_TMP="ipmi_tmp.yml"

if [ ! -f "$PROM_FILE" ]; then
    echo "Ошибка: Запустите скрипт из папки ~/monitoring/"
    exit 1
fi

echo "=== Управление хостами NLRC ==="
echo "1) Добавить новый хост"
echo "2) Удалить хост"
read -p "Выберите действие (1 или 2): " ACTION

if [ "$ACTION" == "1" ]; then
    echo -e "\n--- ДОБАВЛЕНИЕ ХОСТА ---"
    read -p "Введите hostname (например, g10-999): " HOSTNAME
    read -p "Введите team (например, Cloud): " TEAM
    read -p "Введите OS IP: " OS_IP
    read -p "Введите iBMC IP (оставьте пустым, если это ПК без iBMC): " IBMC_IP

    if [ -n "$IBMC_IP" ]; then
        read -p "Введите логин iBMC: " IBMC_LOGIN
        while true; do
            read -s -p "Введите пароль iBMC: " P1; echo
            read -s -p "Повторите пароль iBMC: " P2; echo
            if [ "$P1" = "$P2" ]; then
                IBMC_PASS="$P1"
                break
            else
                echo -e "\e[31mПароли не совпадают! Попробуйте снова.\e[0m"
            fi
        done
    fi

    echo -e "\n--- ВЫБОР СТОЙКИ ---"
    RACKS=($(grep -o '# --- Rack [a-zA-Z0-9]* ---' "$PROM_FILE" | awk '{print $4}' | sort -u))
    for i in "${!RACKS[@]}"; do
        echo "$((i+1))) ${RACKS[$i]}"
    done
    read -p "Выберите номер стойки: " RACK_NUM
    RACK_UPPER="${RACKS[$((RACK_NUM-1))]}"
    RACK_LOWER="${RACK_UPPER,,}"

    echo -e "\n--- ПРОВЕРКА ДАННЫХ ---"
    echo "Hostname:  $HOSTNAME"
    echo "Team:      $TEAM"
    echo "OS IP:     $OS_IP"
    echo "iBMC IP:   ${IBMC_IP:-[Отсутствует]}"
    echo "Rack:      $RACK_LOWER"
    read -p "Все введено корректно? (y/n): " CONFIRM

    if [[ "$CONFIRM" != "y" && "$CONFIRM" != "Y" ]]; then
        echo "Отмена операции."
        exit 0
    fi

    # ПРОВЕРКА МАСТЕР-ПАРОЛЯ ДО ИЗМЕНЕНИЙ В ФАЙЛАХ
    if [ -n "$IBMC_IP" ]; then
        echo -e "\nДля сохранения пароля iBMC требуется расшифровать хранилище."
        read -s -p "Введите мастер-пароль: " MASTER_PASS; echo
        
        openssl enc -aes-256-cbc -d -salt -pbkdf2 -in "$IPMI_ENC" -k "$MASTER_PASS" -out "$IPMI_TMP" 2>/dev/null
        if [ $? -ne 0 ] || [ ! -s "$IPMI_TMP" ]; then
            echo -e "\e[31mОшибка мастер-пароля! Операция прервана. Никаких изменений не внесено.\e[0m"
            rm -f "$IPMI_TMP"
            exit 1
        fi
    fi

    # 1. Добавляем таргет в секцию ICMP (Пинг ОС)
    sed -i "/job_name: 'icmp_ping_servers'/,/job_name:/ {
        /# --- Rack $RACK_UPPER ---/a\\
      - targets: ['$OS_IP']\\
        labels: { hostname: '$HOSTNAME', rack: '$RACK_LOWER', team: '$TEAM' }
    }" "$PROM_FILE"

    # 2. Добавляем таргет в IPMI и обновляем расшифрованный файл
    if [ -n "$IBMC_IP" ]; then
        PARAM_MODULE="ibmc_${IBMC_IP//./_}"
        
        sed -i "/job_name: 'ipmi_servers'/,/job_name:/ {
            /# --- Rack $RACK_UPPER ---/a\\
      - targets: ['$IBMC_IP']\\
        labels: { __param_module: '$PARAM_MODULE', hostname: '$HOSTNAME', rack: '$RACK_LOWER', team: '$TEAM' }
        }" "$PROM_FILE"

        # Дописываем новый модуль
        echo "  $PARAM_MODULE:" >> "$IPMI_TMP"
        echo "    user: \"$IBMC_LOGIN\"" >> "$IPMI_TMP"
        echo "    pass: \"$IBMC_PASS\"" >> "$IPMI_TMP"

        # Зашифровываем обратно
        openssl enc -aes-256-cbc -salt -pbkdf2 -in "$IPMI_TMP" -out "$IPMI_ENC" -k "$MASTER_PASS"
        rm -f "$IPMI_TMP"
        
        MASTER_PASS=""
        IBMC_PASS=""
    fi

    echo -e "\n\e[32mХост $HOSTNAME успешно добавлен!\e[0m"
    echo "Перезапускаем контейнеры Prometheus и IPMI-exporter..."
    docker restart prometheus ipmi-exporter >/dev/null 2>&1 || echo -e "\e[31mНе удалось перезапустить контейнеры автоматически.\e[0m"

elif [ "$ACTION" == "2" ]; then
    echo -e "\n--- УДАЛЕНИЕ ХОСТА ---"
    read -p "Введите hostname для удаления: " HOSTNAME
    read -p "Вы уверены, что хотите удалить $HOSTNAME из мониторинга? (y/n): " CONFIRM
    if [[ "$CONFIRM" == "y" || "$CONFIRM" == "Y" ]]; then
        sed -i "/- targets:.*/{N; /hostname: '$HOSTNAME'/d; }" "$PROM_FILE"
        echo -e "\e[32mХост $HOSTNAME вырезан из prometheus.yml.\e[0m"
        echo "Перезапускаем контейнеры Prometheus..."
        docker restart prometheus >/dev/null 2>&1 || echo -e "\e[31mНе удалось перезапустить Prometheus автоматически.\e[0m"
    else
        echo "Отмена."
    fi
else
    echo "Неверный выбор."
fi
