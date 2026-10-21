-- Spanish UI strings of the rosario plugin. Spanish is the reference
-- language: every other language has these same keys (see i18n.lua).
-- Strings with a "%" are string.format patterns.
return {
    -- The Tools menu entry and the title of the plugin's menu.
    name = "Rosario",
    -- The heading at the top of the screen.
    title = "Santo Rosario",
    restart = "Reiniciar",
    change_mysteries = "Cambiar misterios",
    view_mystery = "Ver misterio",
    hide_text = "Ocultar texto",
    show_text = "Mostrar texto",
    language = "Idioma",
    -- The language menu entry that follows KOReader's language.
    automatic = "Automático (como KOReader)",
    exit = "Salir",
    -- The mystery set of the day in the set chooser.
    today = "%s (hoy)",
    end_hint = "Rosario terminado. Toca para comenzar de nuevo.",
    card_hint = "Toca la pantalla para volver.",
    fruit = "Fruto del misterio: %s",
    -- The scripture fragment of the mystery card.
    quote = "«%s»",
    -- The decade number in the middle of the ring.
    decade_number = "%dº",
    -- Step headings, by prayer of Rosary.steps.
    prayers = {
        sign_of_cross = "Señal de la Cruz",
        creed = "Credo",
        our_father = "Padre Nuestro",
        hail_mary = "Ave María",
        glory_be = "Gloria",
        fatima = "Oh Jesús mío",
        salve = "Salve",
    },
    -- Headings of the five mystery announcements and cards.
    mysteries = {
        "Primer misterio",
        "Segundo misterio",
        "Tercer misterio",
        "Cuarto misterio",
        "Quinto misterio",
    },
}
