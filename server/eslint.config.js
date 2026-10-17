const js = require("@eslint/js");
const globals = require("globals");

module.exports = [
    { ignores: ["node_modules/**", "coverage/**"] },
    js.configs.recommended,
    {
        languageOptions: {
            ecmaVersion: 2024,
            sourceType: "commonjs",
            globals: { ...globals.node, ...globals.jest },
        },
        rules: {
            "no-unused-vars": ["error", { args: "after-used", argsIgnorePattern: "^(req|res|next|doc)$" }],
            "no-const-assign": "error",
        },
    },
];
