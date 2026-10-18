# Baseline

| | |
|---|---|
| Student | Tushar Khurana |
| Student identifier | `<fill in>` |
| Project | URL Shortener: Advanced DevOps project |
| Repository | https://github.com/tusharkhurana2005/UrlShortner (a fork of the original https://github.com/TUSHAR1651/UrlShortner; the history up to and including the baseline is identical in both) |
| Baseline commit | [`12b426b911f0fcad54f184c44ed0040f42bc9d2b`](https://github.com/tusharkhurana2005/UrlShortner/commit/12b426b911f0fcad54f184c44ed0040f42bc9d2b) ("new commit", 3 Nov 2024) |

The baseline commit is the tip of `main` before any work for this project. It
is preserved unchanged in the history; every improvement is on the
`devops/production-readiness` branch and arrives through a single pull request.

Compare baseline to final without the vendored `node_modules`:

```bash
git diff --stat 12b426b9..HEAD -- . ':!client/node_modules' ':!server/node_modules'
```

## The application

A personal MERN URL shortener:

- **client/**: React (Create React App) with Tailwind. Signup and login, then a
  dashboard to shorten URLs, list them, copy and delete.
- **server/**: Express 4 REST API on port 8000. Users and short URLs are stored
  in MongoDB through Mongoose. Passwords are hashed with bcrypt and login
  issues a JWT.
- **MongoDB**: expected at `mongodb://127.0.0.1:27017/Urls`.

## DevOps features that already existed

None. The baseline contains only application source:

| Area | State at baseline |
|---|---|
| Containers | No Dockerfile, no compose file |
| Kubernetes / deployment config | None |
| CI/CD | None (no workflows) |
| Tests | Only the CRA default `App.test.js`, which fails (it looks for "learn react") |
| Configuration | Hard-coded: Mongo URL, JWT secret `'test'`, CORS `http://localhost:3000`, and the client calls `http://localhost:8000` |
| Health checks | None (only `GET /` returning "Hello World!") |
| Logging / metrics / tracing | `console.log` of request bodies; no metrics, no tracing |
| Secrets | JWT signing key committed in source |
| Dependencies | `node_modules/` committed (41,096 files). `npm audit`: server 15 vulnerabilities (3 critical, 10 high), client 112 (4 critical, 85 high) |
| Process | `npm start` runs `nodemon` (a dev tool) in every environment |

## Defects found in the baseline (fixed in the PR)

| Defect | Impact |
|---|---|
| Shortening a URL that was already shortened reassigns a `const` inside an async handler. Express 4 does not catch the rejection, and Node exits on unhandled rejections | **Any user could crash the server** by submitting the same URL twice. Reproduced in [`evidence/00-baseline-crash.txt`](evidence/00-baseline-crash.txt) |
| URL endpoints have no authentication and trust `userId` from the request body | Anyone can list or delete any user's links |
| Login JWT payload embeds the whole user document (`id: user`) | The bcrypt password hash is readable by anyone holding the token |
| Signup and login responses return the user document including the password hash | Password hash exposed to the browser |
| Login returns 200 "User not found" vs 400 "Invalid credentials" | Account enumeration |
| No URL validation | `javascript:` / `data:` links can be stored and served |
| `GET /url/get` returns 200 with `null` for unknown ids | Clients cannot distinguish "not found" |
| `TimeStamp` default `[Date.now()]` is evaluated once, when the schema loads | Every document gets the server start time |
| Single `mongoose.connect` attempt with no retry | If Mongo starts after the API, the API never connects |
