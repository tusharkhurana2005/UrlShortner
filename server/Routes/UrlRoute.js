const express = require("express");
const router = express.Router();
const { createShortUrl , getAllUrls  , getUrl , deleteUrl } = require("../controllers/UrlController");
const { requireAuth } = require("../middleware/auth");

router.post("/create", requireAuth, createShortUrl);
router.get("/get", getUrl);
router.get("/allUrls", requireAuth, getAllUrls);
router.delete("/delete/:id", requireAuth, deleteUrl);



module.exports = router;
