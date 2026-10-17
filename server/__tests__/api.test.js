// Integration tests: real Express app + a throwaway in-memory MongoDB.
const { MongoMemoryServer } = require("mongodb-memory-server");
const mongoose = require("mongoose");
const request = require("supertest");
const { app, state } = require("../app");

let mongod;

beforeAll(async () => {
    mongod = await MongoMemoryServer.create();
    await mongoose.connect(mongod.getUri());
    await mongoose.connection.syncIndexes();
});

afterAll(async () => {
    await mongoose.disconnect();
    await mongod.stop();
});

const signupAndLogin = async (email) => {
    await request(app)
        .post("/api/user/signup")
        .send({ name: "Test", email, password: "password123" })
        .expect(201);
    const res = await request(app)
        .post("/api/user/login")
        .send({ email, password: "password123" })
        .expect(200);
    return res.body.token;
};

describe("health and ops endpoints", () => {
    test("liveness is ok", async () => {
        await request(app).get("/healthz").expect(200);
    });

    test("readiness reflects the database connection", async () => {
        await request(app).get("/readyz").expect(200);
    });

    test("readiness fails while draining", async () => {
        state.shuttingDown = true;
        await request(app).get("/readyz").expect(503);
        state.shuttingDown = false;
    });

    test("version reports build info", async () => {
        const res = await request(app).get("/api/version").expect(200);
        expect(res.body).toHaveProperty("commit");
    });

    test("metrics are exposed in Prometheus format", async () => {
        const res = await request(app).get("/metrics").expect(200);
        expect(res.text).toContain("http_request_duration_seconds");
        expect(res.text).toContain("urlshortener_build_info");
    });
});

describe("users", () => {
    test("signup never returns the password hash", async () => {
        const res = await request(app)
            .post("/api/user/signup")
            .send({ name: "A", email: "a@example.com", password: "password123" })
            .expect(201);
        expect(res.body.User).not.toHaveProperty("password");
    });

    test("duplicate email is rejected with 409", async () => {
        await request(app)
            .post("/api/user/signup")
            .send({ name: "A", email: "A@example.com", password: "password123" })
            .expect(409);
    });

    test("short passwords are rejected", async () => {
        await request(app)
            .post("/api/user/signup")
            .send({ name: "B", email: "b@example.com", password: "short" })
            .expect(400);
    });

    test("unknown user and wrong password both return 401", async () => {
        await request(app)
            .post("/api/user/login")
            .send({ email: "nobody@example.com", password: "password123" })
            .expect(401);
        await request(app)
            .post("/api/user/login")
            .send({ email: "a@example.com", password: "wrong-password" })
            .expect(401);
    });

    test("login token does not embed the user document", async () => {
        const res = await request(app)
            .post("/api/user/login")
            .send({ email: "a@example.com", password: "password123" })
            .expect(200);
        const payload = JSON.parse(Buffer.from(res.body.token.split(".")[1], "base64url").toString());
        expect(payload).toHaveProperty("sub");
        expect(JSON.stringify(payload)).not.toContain("$2b$");
    });
});

describe("urls", () => {
    let token;
    let otherToken;

    beforeAll(async () => {
        token = await signupAndLogin("owner@example.com");
        otherToken = await signupAndLogin("other@example.com");
    });

    test("creating a URL requires authentication", async () => {
        await request(app).post("/api/url/create").send({ Url: "https://example.com" }).expect(401);
    });

    test("invalid and non-http URLs are rejected", async () => {
        for (const Url of ["", "javascript:alert(1)", "ftp://example.com", "http://"]) {
            await request(app)
                .post("/api/url/create")
                .set("Authorization", `Bearer ${token}`)
                .send({ Url })
                .expect(400);
        }
    });

    test("the same URL can be shortened twice (baseline crashed here)", async () => {
        const ids = [];
        for (let i = 0; i < 2; i++) {
            const res = await request(app)
                .post("/api/url/create")
                .set("Authorization", `Bearer ${token}`)
                .send({ Url: "https://example.com/same" })
                .expect(201);
            ids.push(res.body.Url.shortUrl);
        }
        expect(ids[0]).not.toEqual(ids[1]);
    });

    test("full journey: create, list, redirect, delete", async () => {
        const created = await request(app)
            .post("/api/url/create")
            .set("Authorization", `Bearer ${token}`)
            .send({ Url: "example.org/page" })
            .expect(201);
        const shortId = created.body.Url.shortUrl;
        expect(created.body.Url.redirectUrl).toBe("https://example.org/page");

        const list = await request(app)
            .get("/api/url/allUrls")
            .set("Authorization", `Bearer ${token}`)
            .expect(200);
        expect(list.body.urls.map((u) => u.shortUrl)).toContain(shortId);

        const redirect = await request(app).get(`/r/${shortId}`).expect(302);
        expect(redirect.headers.location).toBe("https://example.org/page");

        const lookup = await request(app).get("/api/url/get").query({ shortUrl: shortId }).expect(200);
        expect(lookup.body.url.redirectUrl).toBe("https://example.org/page");

        // Another user can neither see nor delete it.
        const otherList = await request(app)
            .get("/api/url/allUrls")
            .set("Authorization", `Bearer ${otherToken}`)
            .expect(200);
        expect(otherList.body.urls.map((u) => u.shortUrl)).not.toContain(shortId);
        await request(app)
            .delete(`/api/url/delete/${shortId}`)
            .set("Authorization", `Bearer ${otherToken}`)
            .expect(404);

        await request(app)
            .delete(`/api/url/delete/${shortId}`)
            .set("Authorization", `Bearer ${token}`)
            .expect(200);
        await request(app).get(`/r/${shortId}`).expect(404);
    });

    test("unknown short id returns 404", async () => {
        await request(app).get("/api/url/get").query({ shortUrl: "nope123" }).expect(404);
        await request(app).get("/r/nope123").expect(404);
    });
});
