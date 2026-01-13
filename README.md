### Quick start

You need the official server files before starting. Choose one:

- **Manually copy** from your Launcher installation:
  ```
  Windows: %appdata%\Hytale\install\release\package\game\latest
  Linux: $XDG_DATA_HOME/Hytale/install/release/package/game/latest
  MacOS: ~/Application Support/Hytale/install/release/package/game/latest
  ```
- **Use the Hytale Downloader CLI**

Copy the downloaded `Server/` directory and `Assets.zip` into your mapped `/data` folder, then start the container. You'll be prompted to log in.

Enjoy


### Docker compose

```yaml
services:
  hytale:
    image: ghcr.io/visualies/hytale-server:main
    environment:
      HYTALE_OWNER_UUID: ${HYTALE_OWNER_UUID:-}
      JAVA_OPTS: ${JAVA_OPTS:--XX:AOTCache=/data/Server/HytaleServer.aot -Xms8g -Xmx12g}
    volumes:
      - /home/docker/hytale/server/data:/data
    ports:
      - "5520:5520/udp"
    restart: unless-stopped
```
