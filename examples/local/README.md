# Local example

Applies circuit-postgres to a throwaway Rocky Linux 10 container with systemd, creating a user and database called `app`. You need Conn3x and Podman.

```sh
./up.sh
export TF_VAR_app_password='pick-one'
conn3x init
conn3x apply
conn3x plan
```

The second plan says `No changes.` To connect over TCP as `app`:

```sh
podman exec -e PGPASSWORD="$TF_VAR_app_password" circuit-postgres psql -h 127.0.0.1 -U app -d app -c 'SELECT 1'
```

`up.sh` listens on `127.0.0.1:2222`. Set `PORT` to use another port, and pass the same port to Conn3x with `-var port=PORT`. Set `CONTAINERFILE` to test another distro, such as one of the images in Conn3x's `test/images`, which CI uses.

`./down.sh` removes the container, its volumes, the key and the state.
