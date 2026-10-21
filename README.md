# Rosario for KOReader

A [KOReader](https://github.com/koreader/koreader) plugin that guides the Holy Rosary step
by step. It shows a pixel-art bead diagram with soft e-ink animations, the prayer of each
step, and a card for each mystery: its scripture reference and fragment, its fruit and a
short meditation.

Available in Spanish, English, Portuguese, Latin and Italian.

## Install

1. Copy the `rosario.koplugin` folder into KOReader's `plugins/` folder on your device.
2. Restart KOReader.
3. Tap the rosary tab (an icon) right after **Tools** in the top menu, or pick **Rosary** at
   the top of the Tools menu.

Tested on a Kindle with KOReader stable v2026.07.1.

## Features

| Feature | What it does |
|---------|--------------|
| Mysteries of the day | Opens on the day's set, as in *Rosarium Virginis Mariae* 38: Joyful on Monday and Saturday, Sorrowful on Tuesday and Friday, Glorious on Wednesday and Sunday, Luminous on Thursday. |
| Saved progress | Your place is kept for the day. Reopening it the same day resumes where you left off; a new day starts with that day's mysteries. |
| Mystery cards | Each decade opens with its card. The decade's mystery stays in sight above the prayer. |
| Animations | Instead of a vibration, a pixel ripple spreads from each bead as it fills, and a wave of sparkles runs along the beads at each Glory Be. |
| Where to find it | A rosary tab right after **Tools** in the top menu, in both the file browser and the reader, and a **Rosary** entry at the top of the Tools menu. |

### Gestures

| Gesture | Action |
|---------|--------|
| Tap, or swipe left | Next step. If a mystery card is open, close it first. |
| Swipe right | Previous step |
| Swipe down, or the X button | Close the rosary |
| Long-press, or the menu button | Open the menu |

The X and menu buttons are at the top of the screen.

### Menu

| Item | Action |
|------|--------|
| Restart | Go back to the first step, with the same mysteries |
| Change mysteries | Pick another set; today's set is marked "(today)" |
| View mystery | Show the card of the current mystery |
| Hide text / Show text | Hide or show the prayer text |
| Language | Choose the language (see [Languages](#languages)) |
| Exit | Close the rosary |

### End of the rosary

On the last step, a note says the rosary is finished. Moving forward from there (tap or swipe
left) starts a new rosary from the first step.

## Languages

Spanish (`es`), English (`en`), Portuguese (`pt`), Latin (`la`) and Italian (`it`).

The language is chosen in this order:

1. The language picked in the plugin's **Language** menu. The choice is saved and applies at
   once, keeping your place in the rosary.
2. Otherwise, KOReader's own language (for example, `pt_BR` gives Portuguese).
3. Otherwise, English.

**Automatic (follow KOReader)** in the Language menu clears the plugin's own choice. Anything
a language lacks is taken from Spanish.

## Development

Requirements: LuaJIT, Python 3, and curl for regenerating content.

Run the checks from the repository root:

```sh
luajit spec/run.lua                    # Lua specs (no busted needed)
python3 -I spec/gen_content_test.py    # generator tests, offline
```

Regenerate the content of one language:

```sh
python3 -I tools/gen_content.py --lang <code> --cache <dir>
```

- `<code>` is `es`, `en`, `pt`, `la` or `it`.
- Sources are downloaded with curl and cached in `<dir>`. Without `--cache`, a fresh
  temporary folder is used.
- The output is `rosario.koplugin/content/<code>.lua`. Do not edit generated files by hand.

| Path | Contents |
|------|----------|
| `rosario.koplugin/` | The plugin: widget, rosary model, languages, UI strings (`l10n/`), content (`content/`) and fonts |
| `spec/` | Lua specs and the generator tests |
| `tools/gen_content.py` | The content generator |

## Content sources and credits

Prayers and mystery titles come from the Holy See: the "Common prayers" appendix of the
*Compendium of the Catechism of the Catholic Church*, in each language. The Apostles' Creed
and the Our Father are in the body of the same page. Texts from vatican.va are
© Libreria Editrice Vaticana where applicable.

| Language | Prayers and mystery titles | Fatima prayer | Scripture (public domain) |
|----------|----------------------------|---------------|---------------------------|
| Spanish | [Compendio del Catecismo](https://www.vatican.va/archive/compendium_ccc/documents/archive_2005_compendium-ccc_sp.html) | [EWTN](https://www.ewtn.com/es/catolicismo/devociones/oh-jesus-mio-15205) | Torres Amat (1836 edition), [Spanish Wikisource](https://es.wikisource.org/wiki/La_Sagrada_Biblia) |
| English | [Compendium of the Catechism](https://www.vatican.va/archive/compendium_ccc/documents/archive_2005_compendium-ccc_en.html) | [Shrine of Fatima](https://www.fatima.pt/en/pages/fatima-prayers) | Douay-Rheims, Challoner revision, [Project Gutenberg eBook #1581](https://www.gutenberg.org/ebooks/1581) |
| Portuguese | [Compêndio do Catecismo](https://www.vatican.va/archive/compendium_ccc/documents/archive_2005_compendium-ccc_po.html) | [Shrine of Fatima](https://www.fatima.pt/pt/pages/oracoes-de-fatima) | João Ferreira de Almeida, Edição Revista e Corrigida (Lisbon, 1911 reprint of the 1900 edition), [Project Gutenberg eBook #62383](https://www.gutenberg.org/ebooks/62383) |
| Italian | [Compendio del Catechismo](https://www.vatican.va/archive/compendium_ccc/documents/archive_2005_compendium-ccc_it.html) | [Shrine of Fatima](https://www.fatima.pt/it/pages/preghiere-di-fatima) | Antonio Martini, public-domain transcription on [parolaviva.art](https://parolaviva.art/bibbia/) |
| Latin | Latin column of the [English Compendium](https://www.vatican.va/archive/compendium_ccc/documents/archive_2005_compendium-ccc_en.html) | [EWTN](https://www.ewtn.com/catholicism/library/latin-prayers-9125) | Clementine Vulgate, [Latin Wikisource](https://la.wikisource.org/wiki/Vulgata_Clementina) |

- Portuguese quotes Almeida because no clean transcription of the Catholic Figueiredo Bible
  is online. Every rosary passage is in a book both canons share.
- Fruits and meditations are original to this project. They were written in Spanish; the
  other languages are translations of them.
- Each file in `rosario.koplugin/content/` records its sources in its header and in its
  `sources` table.

## License

Copyright (C) 2026 Cesar Tapasco

- The code is licensed under the GNU Affero General Public License, version 3 or later
  (AGPL-3.0-or-later), the same license as KOReader. See [LICENSE](LICENSE).
- The bundled Roboto font is licensed under the SIL Open Font License 1.1. See
  [`rosario.koplugin/fonts/OFL.txt`](rosario.koplugin/fonts/OFL.txt).
- Quoted prayers and scripture come from their respective sources, as credited above.
