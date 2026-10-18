const mongo = require("mongoose");


const urlSchema = new mongo.Schema({
    userId: {
        type: mongo.Schema.Types.ObjectId,
        required: true,
        index: true
    },
    redirectUrl: {
        type: String,
        required: true
    },
    shortUrl: {
        type: String,
        required: true,
        unique: true
    }
}, { timestamps: true })


const Url = mongo.model("Url", urlSchema);
module.exports = Url
