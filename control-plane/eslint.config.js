export default [
    {
        files: ["Public/js/**/*.js"],
        languageOptions: {
            ecmaVersion: 2022,
            sourceType: "script",
            globals: {
                window: "readonly",
                document: "readonly",
                console: "readonly",
                navigator: "readonly",
                location: "readonly",
                btoa: "readonly",
                atob: "readonly",
                fetch: "readonly",
                PublicKeyCredential: "readonly"
            }
        },
        rules: {
            "no-unused-vars": "warn",
            "no-undef": "error",
            "no-console": "off",
            "semi": ["error", "always"],
            "quotes": ["error", "single", { "avoidEscape": true }],
            "indent": ["error", 4],
            "no-trailing-spaces": "error",
            "eol-last": "error",
            "brace-style": ["error", "1tbs"],
            "comma-dangle": ["error", "never"],
            "no-extra-semi": "error",
            "no-unreachable": "error",
            "valid-typeof": "error",
            "no-redeclare": "error"
        }
    }
];