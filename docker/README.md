# Running BirdNET-Pi with Docker

Docker enables BirdNET-Pi to run on **any platform**: Linux, macOS, and Windows — with the full web UI, live audio streaming, and statistics dashboard included.

## Quick Start

```bash
git clone https://github.com/Nachtzuster/BirdNET-Pi.git
cd BirdNET-Pi
cp docker/birdnet.conf.example my-birdnet.conf
# Edit my-birdnet.conf — set LATITUDE and LONGITUDE
docker compose up -d --build
```

Then open [http://localhost](http://localhost) in your browser.

## Configuration

Copy `docker/birdnet.conf.example` to your project root and customize it. Mount it into the container by uncommenting the volume line in `docker-compose.yml`:

```yaml
volumes:
  - ./my-birdnet.conf:/opt/birdnet/birdnet.conf:ro
```

Key settings to customize:

- **LATITUDE / LONGITUDE** (required) — your location, used for species filtering
- **CADDY_PWD** (optional) — set a password to protect admin pages in the web UI
- **ICE_PWD** — Icecast streaming password (default: `birdnetpi`)

You can also pass configuration through environment variables in `docker-compose.yml`:

```yaml
environment:
  - TZ=America/New_York
  - CADDY_PWD=mypassword
  - ICE_PWD=birdnetpi
```

## Web Interface

Once running, the web interface is accessible at [http://localhost](http://localhost):

- **Overview** dashboard with recent detections
- **Species statistics** and daily charts
- **Live spectrogram** viewer
- **Audio playback** for detected clips
- **Settings** management

If `CADDY_PWD` is set, the following pages require authentication: File manager, Processed files, and Live stream.

## Audio Input

The analysis daemon watches for new `.wav` files. There are three ways to provide audio:

### Option 1: RTSP Stream (Recommended for macOS/Windows)

Set `RTSP_STREAM` in your config to an RTSP URL from a network camera, IP microphone, or any RTSP-capable device:

```ini
RTSP_STREAM=rtsp://192.168.1.100:554/audio
```

### Option 2: File Drop

Place `.wav` files directly into the `birdnet-data` volume's `StreamData` directory. The analysis daemon automatically picks up any new WAV files:

```bash
# Find where Docker stores the volume
docker volume inspect birdnet-data

# Or mount a host directory instead (edit docker-compose.yml):
# volumes:
#   - /path/to/your/recordings:/data
```

### Option 3: ALSA Passthrough (Linux Only)

On Linux, pass your audio device into the container. Uncomment in `docker-compose.yml`:

```yaml
devices:
  - /dev/snd:/dev/snd
```

Find your device name on the host:

```bash
arecord -l
```

Then set `REC_CARD` in your config to the ALSA device (e.g. `hw:1,0` for card 1, device 0):

```ini
REC_CARD=hw:1,0
```

> **Note:** macOS and Windows Docker Desktop have no audio device passthrough. Use RTSP (Option 1) instead.

## Live Audio Stream

If audio input is configured, a live stream is available at [http://localhost/stream](http://localhost/stream). The stream is powered by Icecast2 and encoded as MP3.

## Statistics Dashboard

Interactive charts are available at [http://localhost/stats](http://localhost/stats), powered by Streamlit and Plotly.

## Data Persistence

All data is stored in the `birdnet-data` Docker volume:

- Recordings and extracted clips
- SQLite database (`birds.db`)
- Charts

To back up the database:

```bash
docker compose exec birdnet sqlite3 /data/birds.db ".backup '/data/birds-backup.db'"
```

## Building for Different Architectures

The Dockerfile supports both `amd64` and `arm64`:

```bash
# Build for your current platform
docker compose build

# Build multi-arch (requires Docker Buildx)
docker buildx build --platform linux/amd64,linux/arm64 -t birdnet-pi .
```

## Viewing Logs / Troubleshooting

```bash
# Follow all container logs
docker compose logs -f birdnet

# Check individual service status
docker compose exec birdnet supervisorctl status

# Tail logs for a specific service
docker compose exec birdnet supervisorctl tail birdnet_analysis
```

## Stopping

```bash
# Stop containers (data is preserved)
docker compose down

# Stop and remove all data
docker compose down -v
```
