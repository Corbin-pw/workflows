# OpenProject

Runs [OpenProject](https://www.openproject.org/) (work packages, boards, Gantt, wiki,
meetings, time tracking) on a cluster and serves it as a `pw` endpoint on a fixed
subdomain. Users can sign in with their ACTIVATE account.

```
form ──► preprocessing ──► start script ──► OpenProject ──► https://<subdomain>.<sessions domain>/
         (checkout,         (PostgreSQL,     answers /login    the run completes; the service
          checks)            app, proxy)                       runs until you delete the endpoint
```

The first login is `admin` / `admin`; OpenProject asks you to change it right away.

## Two ways to run it

| Run container using | What runs | Needs |
|---|---|---|
| **Singularity** (default) | PostgreSQL 17, OpenProject and nginx from one image, `ghcr.io/parallelworks/openproject:17.0`, all as your user | `singularity`/`apptainer`, about 0.5 GB for the image |
| **Docker** | The official all-in-one image `openproject/openproject:17`, as root | Docker (directly or through `sudo`), 3.3 GB for the image |

Both keep the database and attachments in the **Run directory** (`${HOME}/openproject`),
so a later run on the same directory finds its projects and users again. A run
directory belongs to one runtime: Docker writes it as root, Singularity as you.

On a cluster that loses its home directory when it is restarted or re-provisioned, put
the run directory on the persistent mount instead: projects, users and attachments then survive the restart.
After the restart, delete the stale endpoint the dead service left behind and launch again with the same
run directory.

The first start of a run directory takes about two minutes (database setup); later
starts under one.

## Sign in with ACTIVATE

Single sign-on (OIDC) is an **Enterprise edition** feature: OpenProject hides every
sign-on provider unless it holds an Enterprise token. A 14-day free trial is
available at <https://www.openproject.org/enterprise-edition/> under **Get a free
on-premises trial license**. With a token, this is how to connect it to ACTIVATE:

1. **Pick the address, then register an application for it** (organization admin,
   once). An application is registered for one exact redirect URI, and that URI is
   built from the OpenProject address, which the form's **Subdomain** decides:
   `https://<subdomain>.<sessions domain>/auth/activate/callback`. With the default
   subdomain on activate.parallel.works, that is
   `https://openproject-<user>.activate.pw/auth/activate/callback`. Launching with
   another subdomain later means registering (or updating) the application for the
   new address, or the sign-in stops at a redirect URI error.

   Turn on the *OIDC Applications* preview in your account settings, open
   Organization → Settings → Applications and add a **web** application with that
   redirect URI. You get the client ID at once and the client secret when you create
   one (shown a single time; an admin can reveal it again). The platform docs do not
   describe this page yet. The same through the API:

   ```bash
   pw api -X POST organizations/<org>/oidc/apps --input - <<'EOF'
   {"name": "OpenProject", "kind": "web", "consent": "none", "subjectType": "username",
    "scopes": ["openid", "profile", "email"],
    "redirectUris": ["https://<subdomain>.<sessions domain>/auth/activate/callback"],
    "postLogoutRedirectUris": ["https://<subdomain>.<sessions domain>/"]}
   EOF
   pw api -X POST organizations/<org>/oidc/apps/<clientId>/secrets
   ```

2. **Launch** with the client ID, the client secret and the Enterprise token in the
   *Sign in with ACTIVATE* group. The token is imported once per run directory.
3. **Sign in** with the ACTIVATE button on the login page. A first sign-in creates the
   OpenProject account (login = ACTIVATE username) and asks for the last name once.

Two things to know:

- Open OpenProject in its own tab (`https://<subdomain>.<sessions domain>/`). Inside
  the platform's embedded session view the sign-in cannot complete.
- Use the Singularity runtime for it. The platform proxy rewrites the redirect to the
  sign-in page; the Singularity runtime's nginx works around that, the Docker runtime
  cannot yet.

## Form

| Field | Default | Notes |
|---|---|---|
| Run container using | Singularity | See above |
| Subdomain | `openproject-<username>` | Decides the address, and with it the redirect URI the application must be registered for. Reserve it with `pw subdomains reserve <label>` |
| Run directory | `${HOME}/openproject` | Database, attachments, logs. One run at a time |
| OpenProject image | `openproject/openproject:17` | Docker only. Keep the major version of an existing run directory |
| Client ID | empty | Empty = OpenProject accounts only. A provider stays in the database once configured; remove it under Administration → Authentication |
| Client secret | | Required with a client ID |
| OpenProject Enterprise token | | Required with a client ID until the run directory holds one; bound to the subdomain, has an expiry date |

## Building the Singularity image

```bash
cd workflows/openproject/openproject-singularity
./build-container.sh        # the official slim image plus PostgreSQL 17 and nginx
tools/oras/oras push ghcr.io/parallelworks/openproject:17.0 openproject.sif
```

New OpenProject major, new tag. Keep the package public.
