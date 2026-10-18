# Serve the Kiyu website with Caddy, a small, fast web server
FROM caddy:2-alpine
COPY . /srv
# Railway tells us which port to listen on through $PORT
CMD caddy file-server --root /srv --listen :$PORT