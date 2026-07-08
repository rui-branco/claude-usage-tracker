### Fable weekly limit

The Claude rate-limit section now shows the **per-model weekly cap** (e.g. **Fable**) as its own bar under Session and Weekly — matching what claude.ai shows on its usage page.

- Parses the `weekly_scoped` entries from the usage API's `limits` array (previously the app only read the legacy `five_hour` / `seven_day` fields and dropped the per-model caps)
- Renders one extra weekly bar per scoped model, labelled with the model name and its own reset time
