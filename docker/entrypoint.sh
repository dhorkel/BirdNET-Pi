#!/bin/bash
set -e

# --- 1. Environment variables ---
BIRDNET_HOME="${BIRDNET_HOME:-/opt/birdnet}"
BIRDNET_DATA="${BIRDNET_DATA:-/data}"
BIRDNET_CONFIG="${BIRDNET_CONFIG:-${BIRDNET_HOME}/birdnet.conf}"
export ICE_PWD="${ICE_PWD:-birdnetpi}"
CADDY_PWD="${CADDY_PWD:-}"

export BIRDNET_CONFIG

# --- 2. Data directories ---
mkdir -p "${BIRDNET_DATA}/StreamData"
mkdir -p "${BIRDNET_DATA}/Extracted/By_Date"
mkdir -p "${BIRDNET_DATA}/Extracted/Charts"
mkdir -p "${BIRDNET_DATA}/Processed"

# --- 2b. Legacy home-directory paths expected by PHP/Python code ---
# PHP (play.php, overview.php, species_tools.php, common.php, etc.) and Python
# (daily_plot.py, plotly_streamlit.py, helpers.py) all compute paths as
# ~/BirdSongs/... and ~/BirdNET-Pi/... Symlinks make those resolve correctly.
ln -sf /data /home/birdnet/BirdSongs
ln -sf "${BIRDNET_HOME}" /home/birdnet/BirdNET-Pi

# Shell scripts (spectrogram.sh, livestream.sh, etc.) source /etc/birdnet/birdnet.conf
# directly. Provide a symlink so they find the configurable BIRDNET_CONFIG path.
mkdir -p /etc/birdnet
ln -sf "${BIRDNET_CONFIG}" /etc/birdnet/birdnet.conf

# --- 3. Web root symlinks ---
EXTRACTED="${BIRDNET_DATA}/Extracted"

# Homepage files
ln -sf ${BIRDNET_HOME}/homepage/* ${EXTRACTED}/

# PHP scripts
ln -sf ${BIRDNET_HOME}/scripts ${EXTRACTED}/scripts
ln -sf ${BIRDNET_HOME}/scripts/play.php ${EXTRACTED}/play.php
ln -sf ${BIRDNET_HOME}/scripts/spectrogram.php ${EXTRACTED}/spectrogram.php
ln -sf ${BIRDNET_HOME}/scripts/overview.php ${EXTRACTED}/overview.php
ln -sf ${BIRDNET_HOME}/scripts/stats.php ${EXTRACTED}/stats.php
ln -sf ${BIRDNET_HOME}/scripts/todays_detections.php ${EXTRACTED}/todays_detections.php
ln -sf ${BIRDNET_HOME}/scripts/history.php ${EXTRACTED}/history.php
ln -sf ${BIRDNET_HOME}/scripts/weekly_report.php ${EXTRACTED}/weekly_report.php
ln -sf ${BIRDNET_HOME}/homepage/images/favicon.ico ${EXTRACTED}/favicon.ico

# Model labels
ln -sf ${BIRDNET_HOME}/model/labels.txt ${BIRDNET_HOME}/scripts/labels.txt

# Spectrogram symlink
ln -sf ${BIRDNET_DATA}/StreamData/spectrogram.png ${EXTRACTED}/spectrogram.png

# Species list files in scripts/
for f in exclude_species_list.txt include_species_list.txt whitelist_species_list.txt confirmed_species_list.txt; do
    ln -sf ${BIRDNET_HOME}/$f ${BIRDNET_HOME}/scripts/$f
done

# --- 4. Database initialization ---
DB_PATH="${BIRDNET_DATA}/birds.db"
if [ ! -f "${DB_PATH}" ]; then
    echo "Initializing database..."
    sqlite3 "${DB_PATH}" <<EOF
CREATE TABLE IF NOT EXISTS detections (
  Date DATE,
  Time TIME,
  Sci_Name VARCHAR(100) NOT NULL,
  Com_Name VARCHAR(100) NOT NULL,
  Confidence FLOAT,
  Lat FLOAT,
  Lon FLOAT,
  Cutoff FLOAT,
  Week INT,
  Sens FLOAT,
  Overlap FLOAT,
  File_Name VARCHAR(100) NOT NULL);
CREATE INDEX IF NOT EXISTS "detections_Com_Name" ON "detections" ("Com_Name");
CREATE INDEX IF NOT EXISTS "detections_Sci_Name" ON "detections" ("Sci_Name");
CREATE INDEX IF NOT EXISTS "detections_Date_Time" ON "detections" ("Date" DESC, "Time" DESC);
EOF
    echo "Database initialized."
fi
ln -sf "${DB_PATH}" "${BIRDNET_HOME}/scripts/birds.db"

# --- 5. BirdDB.txt ---
if [ ! -f "${BIRDNET_HOME}/BirdDB.txt" ]; then
    echo "Date;Time;Sci_Name;Com_Name;Confidence;Lat;Lon;Cutoff;Week;Sens;Overlap" > "${BIRDNET_HOME}/BirdDB.txt"
fi

# --- 6. Config file ---
if [ ! -f "${BIRDNET_CONFIG}" ]; then
    echo "Generating default config at ${BIRDNET_CONFIG}..."
    cp "${BIRDNET_HOME}/docker/birdnet.conf.example" "${BIRDNET_CONFIG}"
fi

# --- 6b. Generate default model/labels.txt if not present ---
# set_label_file() reads MODEL and DATABASE_LANG from config and writes
# model/labels.txt from the corresponding model and l18n label files.
if [ ! -f "${BIRDNET_HOME}/model/labels.txt" ]; then
    "${BIRDNET_HOME}/venv/bin/python3" -c \
        "import sys; sys.path.insert(0, '${BIRDNET_HOME}/scripts'); from utils.helpers import set_label_file; set_label_file()"
fi

# --- 7. Icecast password setup ---
ESCAPED_ICE_PWD=$(printf '%s\n' "${ICE_PWD}" | sed 's/[&/\]/\\&/g')
sed -i "s/ICECAST_PWD_PLACEHOLDER/${ESCAPED_ICE_PWD}/g" /etc/icecast2/icecast.xml

# --- 8. Caddy authentication setup ---
if [ -n "${CADDY_PWD}" ]; then
    HASHWORD=$(caddy hash-password --plaintext "${CADDY_PWD}")
    ESCAPED_HASH=$(printf '%s\n' "${HASHWORD}" | sed 's/[&/\]/\\&/g')
    BASICAUTH_BLOCK="  basicauth /views.php?view=File* {\n    birdnet ${ESCAPED_HASH}\n  }\n  basicauth /Processed* {\n    birdnet ${ESCAPED_HASH}\n  }\n  basicauth /scripts* {\n    birdnet ${ESCAPED_HASH}\n  }\n  basicauth /stream {\n    birdnet ${ESCAPED_HASH}\n  }"
    sed -i "/# BASICAUTH_START/,/# BASICAUTH_END/c\\  # BASICAUTH_START\n${BASICAUTH_BLOCK}\n  # BASICAUTH_END" /etc/caddy/Caddyfile
fi

# --- 9. Timezone ---
if [ -n "${TZ}" ]; then
    ln -sf "/usr/share/zoneinfo/${TZ}" /etc/localtime
    echo "${TZ}" > /etc/timezone
fi

# --- 10. PHP-FPM socket directory ---
# /run/ may start empty on container start; ensure dir exists and is writable
# by the birdnet user so php-fpm can create its socket there.
mkdir -p /run/php && chown birdnet:birdnet /run/php

# --- 11. Fix ownership ---
chown -Rh birdnet:birdnet "${BIRDNET_DATA}" "${BIRDNET_HOME}"
chown -R birdnet:birdnet /var/log/icecast2

# --- 12. Launch ---
if [ $# -eq 0 ]; then
    exec /usr/bin/supervisord -c /etc/supervisor/conf.d/birdnet.conf
else
    exec "$@"
fi
