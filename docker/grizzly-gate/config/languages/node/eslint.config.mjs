// Gate-owned ESLint flat config (passed via --config, with --no-config-lookup so
// the repo's eslint config is ignored). Deliberately plugin-free so it resolves
// with only the image's global eslint install — no @eslint/js or
// typescript-eslint import to chase down a node_modules. TypeScript files are
// type-checked by tsc, not parsed here.
export default [
  {
    files: ["**/*.js", "**/*.mjs", "**/*.cjs"],
    languageOptions: {
      ecmaVersion: "latest",
      sourceType: "module",
    },
    rules: {
      "no-unused-vars": "error",
      "no-undef": "error",
      eqeqeq: "error",
      "no-var": "error",
      "prefer-const": "error",
    },
  },
];
