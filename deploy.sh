#!/bin/bash

echo "=== Развертывание мониторинга NLRC ==="

echo -n "Введите мастер-пароль для расшифровки: "
read -s MASTER_PASS
echo ""

# Расшифровываем файл напрямую в переменную оболочки
export IPMI_YAML_CONTENT=$(openssl enc -aes-256-cbc -d -salt -pbkdf2 -in ipmi/ipmi.yml.enc -k "$MASTER_PASS" 2>/dev/null)

if [ -z "$IPMI_YAML_CONTENT" ]; then
    echo "Ошибка: Неверный пароль или пустой файл!"
    exit 1
fi

echo "Конфиг успешно прочитан в память. Поднимаем стек..."
docker compose up -d

echo "Ожидание готовности Grafana API..."
# Пингуем API, пока не получим ответ (HTTP 200 OK)
until curl -s http://localhost:3000/api/health > /dev/null; do
    echo -n "."
    sleep 2
done
echo -e "\nГрафана запущена и готова к приему команд!"

echo "Создание пользователя monitoring (только просмотр)..."
# Создаем пользователя. Если он уже есть, curl просто тихо вернет ошибку (подавляем вывод)
curl -s -X POST -H "Content-Type: application/json" \
  -d '{"name":"Monitoring Viewer","email":"monitoring@nlrc.local","login":"monitoring","password":"monitoring"}' \
  http://admin:admin@localhost:3000/api/admin/users > /dev/null

echo "Настраиваем фоновый сбор метрик..."
# Выдаем права скрипту-парсеру
chmod 700 /home/neo/monitoring/get_power.sh

CRON_JOB="* * * * * /home/neo/monitoring/get_power.sh >/dev/null 2>&1"

# Идемпотентно добавляем задачу в крон (если её там еще нет)
if ! crontab -l 2>/dev/null | grep -F "$CRON_JOB" >/dev/null; then
    (crontab -l 2>/dev/null; echo "$CRON_JOB") | crontab -
    echo "Задача cron успешно добавлена."
else
    echo "Задача cron уже существует. Пропускаем."
fi

# Стираем пароли из оперативной памяти терминала
unset IPMI_YAML_CONTENT
MASTER_PASS=""

echo "=== Готово! ==="
