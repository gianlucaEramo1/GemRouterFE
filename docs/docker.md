# Deploy con Docker

Alternativa al setup systemd descritto in [operations](operations.md). Usa lo stesso
`.env` nella radice del repository e gli stessi dati; cambia solo il modo in cui il
processo viene costruito, avviato e aggiornato.

Tutti i file Docker stanno in [`ops/docker/`](../ops/docker), accanto a
`ops/systemd/` e `ops/cloudflared/`:

| File | Ruolo |
|---|---|
| [`Dockerfile`](../ops/docker/Dockerfile) | Build multi-stage: Node 24.18 su Debian slim, utente non root `node`, healthcheck su `/health` |
| [`Dockerfile.dockerignore`](../ops/docker/Dockerfile.dockerignore) | Tiene `.env`, `data/` e gli altri segreti fuori dalla build |
| [`docker-compose.yml`](../ops/docker/docker-compose.yml) | Servizio `gemrouter`, rete `gemrouter_default`, volumi persistenti, porta pubblicata solo su `127.0.0.1` |
| [`deploy.sh`](../ops/docker/deploy.sh) | Unico comando da usare: build, avvio, rollback automatico, log, stato |

Lo script si può lanciare da qualunque cartella: lavora sempre dalla radice del
repository, dove si trova il `.env`. Richiede Docker Engine 23 o successivo con il
plugin Compose v2 (`docker compose version`).

## Dati persistenti

Tutto lo stato vive in volumi Docker, quindi sopravvive a rebuild e aggiornamenti.
Docker antepone il nome del progetto (`gemrouter_`) al nome del volume.

| Volume | Percorso nel container | Contenuto |
|---|---|---|
| `gemrouter_data` | `/app/data` | Account Gemini **con le chiavi in chiaro**, app client, ledger quota, interazioni (prompt e risposte), audit |
| `gemrouter_runtime` | `/app/.runtime` | Versioni del runtime Codex attivate dalla dashboard |
| `gemrouter_backups` | `/app/backups` | Backup privati e copie di sicurezza prima di un import |
| `gemrouter_codex` | `/home/node/.local/share/gemrouter-personal-control` | Login Codex (solo se usi Codex) |

Il `.env` resta sul server, nella radice del repository, e non entra mai
nell'immagine.

## Primo deploy

1. Clona il repository e prepara il `.env`:

   ```bash
   git clone <url-del-repository> gemrouter && cd gemrouter
   cp .env.example .env && chmod 600 .env
   ```

2. Compila almeno questi valori (genera i segreti con `openssl rand -hex 32`):

   ```env
   GEMROUTER_ADMIN_TOKEN=<segreto>
   GEMROUTER_DASHBOARD_ADMIN_USERS=admin:<password>
   GEMROUTER_BOOTSTRAP_API_KEY=<segreto>
   GEMROUTER_BOOTSTRAP_MODEL_ACCESS=all
   GEMROUTER_BACKEND_ORDER=gemini-api
   GEMROUTER_GEMINI_API_ENABLED=true
   GEMROUTER_GEMINI_API_DEFAULT_TIER=free
   GEMROUTER_NVIDIA_ENABLED=false
   ```

   Le chiavi Gemini puoi metterle in `GEMROUTER_GEMINI_API_KEYS` oppure aggiungerle
   dopo dalla dashboard. Docker Compose interpreta il carattere `$` nei valori del
   `.env` come una variabile: una password che lo contiene va scritta tra apici
   singoli, per esempio `GEMROUTER_DASHBOARD_ADMIN_USERS='admin:pa$sword'` (vale anche
   per systemd). `HOST`, `PORT`, `GEMROUTER_ROOT_DIR`, `GEMROUTER_DATA_DIR` e
   `GEMROUTER_CODEX_PRIVATE_DIR` sono impostati dal compose: nel `.env` vengono ignorati.
   Non impostare `GEMROUTER_CODEX_COMMAND`, che disattiverebbe il runtime Codex incluso.

3. Avvia il router. Il primo avvio crea anche la rete `gemrouter_default`:

   ```bash
   bash ops/docker/deploy.sh
   ```

4. Collega n8n alla rete del router, come già fa con `ridemate-mon_default` e
   `ridemate-automation_default`. Nel `docker-compose.yml` di n8n aggiungi la rete
   esterna e mettila anche nell'elenco `networks` del servizio n8n:

   ```yaml
   services:
     n8n:
       networks:
         # ...reti già presenti...
         - gemrouter

   networks:
     # ...reti già presenti...
     gemrouter:
       external: true
       name: gemrouter_default
   ```

   Poi ricrea il container di n8n dalla sua cartella con `docker compose up -d`. n8n
   si riavvia per qualche secondo: fallo quando non ci sono esecuzioni in corso. Da
   quel momento n8n chiama il router come `http://gemrouter:4024`, senza porte aperte.

   La rete deve esistere quando n8n si avvia. Dopo un riavvio del server Docker fa
   ripartire entrambi gli stack da solo; se invece elimini lo stack del router,
   rilancialo prima di ricreare n8n.

5. Verifica dal server e dal container di n8n:

   ```bash
   curl -fsS http://127.0.0.1:4024/health
   docker exec <container-n8n> node -e "fetch('http://gemrouter:4024/health').then((r) => console.log(r.status))"
   ```

## Dashboard

La porta è pubblicata solo sull'interfaccia di loopback del server. Docker scavalca
le regole di `ufw` per le porte pubblicate, quindi non cambiare `127.0.0.1:` in
`4024:4024`. Dal tuo computer apri un tunnel SSH:

```bash
ssh -L 4024:127.0.0.1:4024 <utente>@<server>
```

e visita `http://127.0.0.1:4024/admin`. Da lì:

- **Gemini Accounts**: aggiungi le chiavi, ognuna con il proprio `quotaGroup` se
  appartiene a un progetto Google diverso, e `tier: free` per le chiavi gratuite.
- **Apps and API Keys**: crea un'app `n8n` con **All configured models** e limiti
  adeguati ai tuoi flussi. La chiave viene mostrata una sola volta.

## Collegare n8n

In n8n crea una credenziale **OpenAI** con:

- **API Key**: la chiave dell'app `n8n`;
- **Base URL**: `http://gemrouter:4024/v1`.

Poi sostituisci i nodi "Google Gemini Chat Model" con "OpenAI Chat Model" e questa
credenziale. Limiti del router da tenere presenti: niente tool calling, niente
ricerca Google/URL context, le immagini in input non vengono inoltrate a Gemini.

## Comandi

| Comando | Cosa fa |
|---|---|
| `bash ops/docker/deploy.sh` | Costruisce il codice attuale e lo mette in servizio, con rollback automatico |
| `bash ops/docker/deploy.sh rollback` | Torna alla build precedente |
| `bash ops/docker/deploy.sh rollback a1b2c3d` | Torna a una build specifica (hash del commit) |
| `bash ops/docker/deploy.sh restart` | Ricrea il container per rileggere il `.env`, senza rebuild |
| `bash ops/docker/deploy.sh status` | Stato del container e build disponibili |
| `bash ops/docker/deploy.sh logs` | Segue il log del container |
| `bash ops/docker/deploy.sh config` | Mostra come Compose legge configurazione, rete e porte, senza avviare nulla |
| `docker image rm gemrouter:<tag>` | Elimina una build vecchia |

## Aggiornare dopo una modifica al codice

1. In locale: `pnpm check && pnpm test`, poi commit e push.
2. Sul server:

   ```bash
   git pull && bash ops/docker/deploy.sh
   ```

Lo script costruisce la nuova immagine mentre il container attuale continua a
servire, la etichetta con l'hash del commit, sostituisce il container e attende che
`/health` risponda. Se non risponde entro 120 secondi torna da solo all'immagine
precedente. Una richiesta in corso durante il cambio ha fino a 90 secondi per finire.

Se cambi solo il `.env` usa `restart`: `docker restart gemrouter` **non** rilegge
il `.env`.

## Backup dei volumi

```bash
docker run --rm -v gemrouter_data:/data:ro -v "$PWD":/backup debian:bookworm-slim \
  tar czf /backup/gemrouter-data-$(date +%F).tar.gz -C /data .
```

Il file contiene le chiavi Gemini in chiaro e i prompt registrati: conservalo come
una credenziale. Fai lo stesso per `gemrouter_codex` se usi Codex.

## Differenze rispetto a systemd

- **Riavvio notturno**: non incluso; `restart: unless-stopped` riavvia il container se
  il processo si ferma. Se lo vuoi comunque: `30 3 * * * docker restart gemrouter` in
  crontab.
- **Import di un backup dalla dashboard**: ripristina `data/`, ma il `.env` vive sul
  server e va ripristinato a mano.
- **Codex**: funziona come con systemd (runtime linux-x64 incluso). Il login con
  device code dalla dashboard viene salvato nel volume `gemrouter_codex`.

## Eliminare tutto

Scollega prima n8n dalla rete (togli `gemrouter` dal suo compose e ricrealo),
altrimenti Docker non può rimuoverla. Poi, dalla radice del repository:

```bash
docker compose -f ops/docker/docker-compose.yml --env-file .env down -v
```

`-v` cancella anche i volumi, cioè chiavi, app e login: fai prima un backup.
