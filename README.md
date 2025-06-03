# SSL-enabled Postgres DB image

This repository contains the logic to build SSL-enabled Postgres images that have postgis and pgvector extensions added.


## What you'll need

For a quick setup, you'll need the following:

1. Create a new service on the Railway project and link it to this repo.

2. Add the required environment variables:

    - Add a new environment variable: `RAILWAY_DOCKERFILE_PATH`. It's value should be the docker file you need to use e.g. `RAILWAY_DOCKERFILE_PATH="./Dockerfile.17"`

    - Add all the service variables from the official postgres template. When you spin up a new postgres service on railway, it comes with the following 12 service variables:
        ```
        DATABASE_PUBLIC_URL="postgresql://${{PGUSER}}:${{POSTGRES_PASSWORD}}@${{RAILWAY_TCP_PROXY_DOMAIN}}:${{RAILWAY_TCP_PROXY_PORT}}/${{PGDATABASE}}"
        DATABASE_URL="postgresql://${{PGUSER}}:${{POSTGRES_PASSWORD}}@${{RAILWAY_PRIVATE_DOMAIN}}:5432/${{PGDATABASE}}"
        PGDATA="/var/lib/postgresql/data/pgdata"
        PGDATABASE="${{POSTGRES_DB}}"
        PGHOST="${{RAILWAY_PRIVATE_DOMAIN}}"
        PGPASSWORD="${{POSTGRES_PASSWORD}}"
        PGPORT="5432"
        PGUSER="${{POSTGRES_USER}}"
        POSTGRES_DB="railway"
        POSTGRES_PASSWORD=""
        POSTGRES_USER="postgres"
        SSL_CERT_DAYS="820"
        ```
    - You can copy this to the `Variables` -> `Raw Editor` tab and update the POSTGRES_PASSWORD variable to a randomly generated 32 character string.

3. Setting POSTGRES_PASSWORD

    - When updating POSTGRES_PASSWORD, be careful with the choice of password to avoid connection errors *(e.g., “password authentication failed for user ‘postgres’”)* when         using DBeaver, psql, or Railway.

    - You have two options:

        **Option 1:** Use only letters (A–Z, a–z) for your password
        ```
        POTGRES_PASSWORD=mysecurepassword
         ```
        **Option 2:** If your password must contain numbers or special characters, always wrap it in single quotes
        ```
        POSTGRES_PASSWORD='pa$$w0rd123!'
        ```
4. Attach a volume to the service by right clicking on the service and set the mount path to: `/var/lib/postgresql/data`. After this step, you should have 10 Railway Provided Variables.

5. Deploy to apply the changes.

6. Configure a TCP Proxy for the service by navigating to `Settings` -> `Networking` and selecting the default port 5432. Ensure that only the TCP Proxy is added. This should bring the total of Railway Provided variables to 13.

7. Redeploy the service.
