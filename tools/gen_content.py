#!/usr/bin/env python3
"""Generate rosario.koplugin/content/<lang>.lua from public sources.

Each language with content of its own has a builder here (see BUILDERS). The
plugin fills whatever a language module lacks from the Spanish one, key by key.

Prayers and mystery titles come from the Holy See: the Compendium of the
Catechism of the Catholic Church, in each language. The prayers are in its
appendix "Common prayers", except the Apostles' Creed and the Our Father,
which are in the body of the same page. The Latin texts are the Latin column
of the English edition, which also holds the Latin mystery titles.

The Fatima prayer is not in the Compendium. It comes from EWTN (Spanish and
Latin) and from the Shrine of Fatima (English, Portuguese and Italian).

Scripture fragments are quoted from public-domain translations:

    es  Torres Amat (1836 edition), Spanish Wikisource
    en  Douay-Rheims, Challoner revision, Project Gutenberg eBook #1581
    it  Antonio Martini, public-domain transcription on parolaviva.art
    la  Clementine Vulgate, Latin Wikisource
    pt  João Ferreira de Almeida, Edição Revista e Corrigida (Lisbon, 1911
        reprint of the 1900 edition), Project Gutenberg eBook #62383. No
        clean transcription of the Catholic Figueiredo Bible is online (only
        scans with OCR errors). Almeida is a Protestant translation, but every
        rosary passage is in a book both canons share. This is not one of the
        copyrighted modern revisions (ARC 1995/2009, ARA, ACF, NAA).

A mystery whose verses a source lacks gets no scripture key in a language
other than Spanish: the generator reports it on stderr, still succeeds, and
the plugin shows the Spanish fragment.

Fruits and meditations are original text written for this plugin and live in
this script as data. The Spanish text is the original; the other languages
are translations of it.

Usage:
    python3 -I tools/gen_content.py [--lang LANG] [--cache DIR] [--out PATH]

LANG is a language of BUILDERS (default es). The output defaults to
rosario.koplugin/content/LANG.lua.

Downloads use curl. Downloaded files are cached in DIR (a fresh temporary
directory by default) and are only parsed as data.
"""

import argparse
import html
import json
import os
import re
import subprocess
import sys
import tempfile
import time
import urllib.parse

VATICAN_PAGE = ("https://www.vatican.va/archive/compendium_ccc/documents/"
                "archive_2005_compendium-ccc_%s.html")
VATICAN_URL = VATICAN_PAGE % "sp"
EWTN_FATIMA_URL = "https://www.ewtn.com/es/catolicismo/devociones/oh-jesus-mio-15205"
WIKISOURCE_API = "https://es.wikisource.org/w/api.php"
WIKISOURCE_PAGE = "https://es.wikisource.org/wiki/"

USER_AGENT = "rosario-koplugin-content-generator/1.0 (offline build script)"

# Wikisource book pages of the Torres Amat Bible, keyed by the Spanish
# abbreviation used in references.
BOOKS = {
    "Mt": "La Sagrada Biblia (XIII)/Mateo",
    "Mc": "La Sagrada Biblia (XIII)/Marcos",
    "Lc": "La Sagrada Biblia (XIII)/Lucas",
    "Jn": "La Sagrada Biblia (XIII)/Juan",
    "Hch": "La Sagrada Biblia (XIV)/Hechos",
    "Ap": "La Sagrada Biblia (XV)/Apocalipsis",
}

# Compendium page of each language: the language code in its URL, and the
# anchor of the appendix "Common prayers", which prayer sources point to.
# Latin is read from the English page.
COMPENDIUM = {
    "es": ("sp", "ORACIONES COMUNES"),
    "en": ("en", "A) COMMON PRAYERS"),
    "pt": ("po", "A) ORAÇÕES COMUNS"),
    "it": ("it", "A) PREGHIERE COMUNI"),
    "la": ("en", "A) COMMON PRAYERS"),
}

# Prayer id -> title, and heading of its cell in the Compendium. The first
# cell with that heading is used. Options: "variant" takes the line that
# follows a marker line (the English Salve has a UK and a US version);
# "until" ends the text where a marker starts (the Portuguese Salve is
# followed by its versicle and response).
PRAYERS = {
    "es": [
        ("sign_of_cross", "Señal de la Cruz", "Señal de la Cruz"),
        ("creed", "Credo", "Símbolo de los Apóstoles"),
        ("our_father", "Padre Nuestro", "Padre nuestro"),
        ("hail_mary", "Ave María", "Ave María"),
        ("glory_be", "Gloria", "Gloria al Padre"),
        ("salve", "Salve", "Salve Regina"),
    ],
    "en": [
        ("sign_of_cross", "Sign of the Cross", "The Sign of the Cross"),
        ("creed", "Apostles' Creed", "The Apostles’ Creed"),
        ("our_father", "Our Father", "Our Father"),
        ("hail_mary", "Hail Mary", "The Hail Mary"),
        ("glory_be", "Glory Be", "Glory be to the Father"),
        ("salve", "Hail, Holy Queen", "Hail Holy Queen", {"variant": "UK VERSION"}),
    ],
    "pt": [
        ("sign_of_cross", "Sinal da Cruz", "Sinal da Cruz"),
        ("creed", "Credo", "Símbolo dos Apóstolos"),
        ("our_father", "Pai-Nosso", "Pai Nosso"),
        ("hail_mary", "Ave-Maria", "Avé Maria"),
        ("glory_be", "Glória", "Glória ao Pai"),
        ("salve", "Salve Rainha", "Salve Rainha", {"until": "Rogai por nós"}),
    ],
    "it": [
        ("sign_of_cross", "Segno della Croce", "Segno della Croce"),
        ("creed", "Credo", "Simbolo degli Apostoli"),
        ("our_father", "Padre Nostro", "Padre Nostro"),
        ("hail_mary", "Ave Maria", "Ave, Maria"),
        ("glory_be", "Gloria", "Gloria al Padre"),
        ("salve", "Salve Regina", "Salve, Regina"),
    ],
    "la": [
        ("sign_of_cross", "Signum Crucis", "Signum Crucis"),
        ("creed", "Symbolum Apostolorum", "Symbolum Apostolicum"),
        ("our_father", "Pater Noster", "Pater Noster"),
        ("hail_mary", "Ave Maria", "Ave, Maria"),
        ("glory_be", "Gloria Patri", "Gloria Patri"),
        ("salve", "Salve Regina", "Salve, Regina"),
    ],
}

# The Fatima prayer: page, a phrase of its paragraph, and its title.
FATIMA = {
    "es": (EWTN_FATIMA_URL, "fuego del infierno", "Oh Jesús mío"),
    "en": ("https://www.fatima.pt/en/pages/fatima-prayers", "fire of hell", "O my Jesus"),
    "pt": ("https://www.fatima.pt/pt/pages/oracoes-de-fatima", "fogo do inferno", "Ó meu Jesus"),
    "it": ("https://www.fatima.pt/it/pages/preghiere-di-fatima", "fuoco dell", "O Gesù mio"),
    "la": ("https://www.ewtn.com/catholicism/library/latin-prayers-9125",
           "Domine Iesu, dimitte", "Oratio Fatimae"),
}

SET_ORDER = ["gozosos", "luminosos", "dolorosos", "gloriosos"]

# Set titles, drawn with the plugin's bitmap font: only characters it has
# glyphs for (Latin writes "ae", never "æ").
SET_TITLES = {
    "es": {
        "gozosos": "Misterios Gozosos",
        "luminosos": "Misterios Luminosos",
        "dolorosos": "Misterios Dolorosos",
        "gloriosos": "Misterios Gloriosos",
    },
    "en": {
        "gozosos": "Joyful Mysteries",
        "luminosos": "Mysteries of Light",
        "dolorosos": "Sorrowful Mysteries",
        "gloriosos": "Glorious Mysteries",
    },
    "pt": {
        "gozosos": "Mistérios Gozosos",
        "luminosos": "Mistérios da Luz",
        "dolorosos": "Mistérios Dolorosos",
        "gloriosos": "Mistérios Gloriosos",
    },
    "it": {
        "gozosos": "Misteri della gioia",
        "luminosos": "Misteri della luce",
        "dolorosos": "Misteri del dolore",
        "gloriosos": "Misteri della gloria",
    },
    "la": {
        "gozosos": "Mysteria Gaudiosa",
        "luminosos": "Mysteria Luminosa",
        "dolorosos": "Mysteria Dolorosa",
        "gloriosos": "Mysteria Gloriosa",
    },
}

# Mystery titles in the Compendium (not Spanish): the heading of each set, in
# SET_ORDER, and whether its titles come one per line ("lines") or end with a
# full stop and may wrap ("sentences").
TITLE_HEADINGS = {
    "en": (["The Joyful Mysteries", "The Mysteries of Light",
            "The Sorrowful Mysteries", "The Glorious Mysteries"], "lines"),
    "pt": (["Mistérios Gozosos", "Mistérios da Luz",
            "Mistérios Dolorosos", "Mistérios Gloriosos"], "sentences"),
    "it": (["Misteri della gioia", "Misteri della luce",
            "Misteri del dolore", "Misteri della gloria"], "sentences"),
    "la": (["Mystéria gaudiósa", "Mystéria luminósa",
            "Mystéria dolorósa", "Mystéria gloriósa"], "sentences"),
}

# Per mystery: reference shown on the card, scripture fragment as a list of
# (book, chapter, first verse, last verse), traditional fruit and an original
# meditation (2-3 sentences).
MYSTERIES = {
    "gozosos": [
        {
            "reference": "Lc 1, 26-38",
            "fragment": [("Lc", 1, 30, 31), ("Lc", 1, 38, 38)],
            "fruit": "La humildad",
            "meditation": (
                "Dios pide permiso a una joven de Nazaret para hacerse hombre. "
                "María escucha, pregunta y se entrega por completo a su palabra. "
                "Pidamos un corazón dispuesto a decir sí a lo que Dios quiera."
            ),
        },
        {
            "reference": "Lc 1, 39-56",
            "fragment": [("Lc", 1, 41, 42)],
            "fruit": "La caridad con el prójimo",
            "meditation": (
                "María, llevando a Jesús en su seno, sale de prisa a servir a su prima. "
                "Su visita llena de alegría a Isabel y al niño que espera. "
                "Pidamos llevar a Cristo a los demás con gestos sencillos de servicio."
            ),
        },
        {
            "reference": "Lc 2, 1-20",
            "fragment": [("Lc", 2, 6, 7)],
            "fruit": "La pobreza de espíritu",
            "meditation": (
                "El Hijo de Dios nace en la pobreza de un pesebre. "
                "Los primeros en adorarlo son unos pastores sencillos. "
                "Pidamos un corazón libre de apegos, que sepa hacer sitio a Jesús."
            ),
        },
        {
            "reference": "Lc 2, 22-40",
            "fragment": [("Lc", 2, 22, 22), ("Lc", 2, 30, 32)],
            "fruit": "La obediencia y la pureza",
            "meditation": (
                "María y José cumplen la ley y ofrecen al Niño en el templo. "
                "Simeón reconoce en Él la luz de las naciones y anuncia a María una espada de dolor. "
                "Pidamos ofrecer a Dios nuestra vida con fidelidad y confianza."
            ),
        },
        {
            "reference": "Lc 2, 41-52",
            "fragment": [("Lc", 2, 46, 46), ("Lc", 2, 48, 49)],
            "fruit": "La búsqueda de Dios en todas las cosas",
            "meditation": (
                "Después de tres días de angustia, María y José encuentran a Jesús en el templo. "
                "Él les recuerda que debe ocuparse de las cosas de su Padre. "
                "Pidamos buscar siempre a Jesús, también cuando parece que lo hemos perdido."
            ),
        },
    ],
    "luminosos": [
        {
            "reference": "Mt 3, 13-17",
            "fragment": [("Mt", 3, 16, 17)],
            "fruit": "La fidelidad a las promesas del bautismo",
            "meditation": (
                "Jesús, que no tiene pecado, se pone en la fila de los pecadores en el Jordán. "
                "El cielo se abre y el Padre lo proclama su Hijo amado. "
                "Pidamos vivir como hijos de Dios, fieles a nuestro bautismo."
            ),
        },
        {
            "reference": "Jn 2, 1-11",
            "fragment": [("Jn", 2, 3, 5)],
            "fruit": "La confianza en Jesús por medio de María",
            "meditation": (
                "En Caná, María advierte la necesidad de los novios antes que nadie. "
                "Su consejo sigue siendo el mismo: hagan lo que Él les diga. "
                "Pidamos confiar nuestras necesidades a Jesús por medio de su Madre."
            ),
        },
        {
            "reference": "Mc 1, 14-15",
            "fragment": [("Mc", 1, 14, 15)],
            "fruit": "La conversión del corazón",
            "meditation": (
                "Jesús anuncia que el Reino de Dios está cerca y llama a la conversión. "
                "Su misericordia acoge a todo el que vuelve a Él. "
                "Pidamos un corazón arrepentido que crea en el Evangelio."
            ),
        },
        {
            "reference": "Mt 17, 1-8",
            "fragment": [("Mt", 17, 1, 2), ("Mt", 17, 5, 5)],
            "fruit": "El deseo de santidad",
            "meditation": (
                "En el monte, Jesús deja ver a sus discípulos la gloria de Dios. "
                "El Padre nos pide escuchar a su Hijo amado. "
                "Pidamos dejarnos transformar por su luz en la oración."
            ),
        },
        {
            "reference": "Mt 26, 26-29",
            "fragment": [("Mt", 26, 26, 28)],
            "fruit": "La adoración y el amor a la Eucaristía",
            "meditation": (
                "En la última cena, Jesús se entrega a sí mismo en el pan y en el vino. "
                "Se queda con nosotros para siempre en la Eucaristía. "
                "Pidamos recibirlo con fe y adorarlo con amor."
            ),
        },
    ],
    "dolorosos": [
        {
            "reference": "Lc 22, 39-46",
            "fragment": [("Lc", 22, 41, 42), ("Lc", 22, 44, 44)],
            "fruit": "La conformidad con la voluntad de Dios",
            "meditation": (
                "En Getsemaní, Jesús siente la angustia ante la pasión que se acerca. "
                "Ora con insistencia y se abandona en las manos del Padre. "
                "Pidamos aceptar la voluntad de Dios también en la hora de la prueba."
            ),
        },
        {
            "reference": "Jn 19, 1",
            "fragment": [("Jn", 19, 1, 1)],
            "fruit": "La mortificación de los sentidos",
            "meditation": (
                "Jesús es azotado en silencio por nuestros pecados. "
                "Sus heridas son el precio de nuestra curación. "
                "Pidamos la gracia de ofrecer nuestros sufrimientos unidos a los suyos."
            ),
        },
        {
            "reference": "Mt 27, 27-31",
            "fragment": [("Mt", 27, 28, 29)],
            "fruit": "La humildad y el desprecio de la vanidad",
            "meditation": (
                "Los soldados se burlan de Jesús y lo coronan de espinas como a un rey de burla. "
                "Él, verdadero Rey, soporta la humillación con mansedumbre. "
                "Pidamos un corazón humilde que no busque la gloria del mundo."
            ),
        },
        {
            "reference": "Jn 19, 16-17; Lc 23, 26-32",
            "fragment": [("Jn", 19, 17, 17), ("Lc", 23, 26, 26)],
            "fruit": "La paciencia en las cruces de cada día",
            "meditation": (
                "Jesús carga con la cruz camino del Calvario y cae bajo su peso. "
                "Simón de Cirene le ayuda a llevarla. "
                "Pidamos cargar con paciencia nuestra cruz y ayudar a otros con la suya."
            ),
        },
        {
            "reference": "Lc 23, 33-46",
            "fragment": [("Lc", 23, 33, 34), ("Lc", 23, 46, 46)],
            "fruit": "El perdón y la perseverancia final",
            "meditation": (
                "Clavado en la cruz, Jesús perdona a quienes lo crucifican. "
                "Entrega su espíritu al Padre y nos da a María como Madre. "
                "Pidamos saber perdonar y perseverar en su amor hasta el final."
            ),
        },
    ],
    "gloriosos": [
        {
            "reference": "Lc 24, 1-8",
            "fragment": [("Lc", 24, 5, 6)],
            "fruit": "La fe",
            "meditation": (
                "Al tercer día, el sepulcro está vacío: Cristo ha vencido a la muerte. "
                "Las mujeres son las primeras en recibir la gran noticia. "
                "Pidamos una fe viva que anuncie con alegría que Él vive."
            ),
        },
        {
            "reference": "Hch 1, 6-11",
            "fragment": [("Hch", 1, 9, 11)],
            "fruit": "La esperanza y el deseo del cielo",
            "meditation": (
                "Jesús sube al cielo ante la mirada de sus discípulos. "
                "No nos deja solos: prepara un lugar para nosotros y volverá. "
                "Pidamos vivir con la mirada puesta en el cielo y los pies en la tierra."
            ),
        },
        {
            "reference": "Hch 2, 1-4",
            "fragment": [("Hch", 2, 2, 4)],
            "fruit": "Los dones del Espíritu Santo",
            "meditation": (
                "Reunidos con María en oración, los apóstoles reciben el Espíritu Santo. "
                "El miedo se convierte en valentía para anunciar a Cristo. "
                "Pidamos ser dóciles al Espíritu y dar testimonio de nuestra fe."
            ),
        },
        {
            "reference": "Lc 1, 48-49",
            "fragment": [("Lc", 1, 48, 49)],
            "fruit": "La gracia de una buena muerte",
            "meditation": (
                "Al terminar su vida en la tierra, María es llevada en cuerpo y alma al cielo. "
                "En ella vemos el destino que Dios prepara a sus hijos. "
                "Pidamos vivir de tal modo que un día nos encontremos con ella en la gloria."
            ),
        },
        {
            "reference": "Ap 12, 1",
            "fragment": [("Ap", 12, 1, 1)],
            "fruit": "La confianza en la intercesión de María",
            "meditation": (
                "María es coronada como Reina del cielo y de la tierra. "
                "Su realeza es servicio: intercede sin descanso por sus hijos. "
                "Pidamos acudir a ella con la confianza de quien acude a su Madre."
            ),
        },
    ],
}

# Fruits and meditations of MYSTERIES translated from the Spanish, in the
# same order: per set, five (fruit, meditation) pairs.
TRANSLATIONS = {
    "en": {
        "gozosos": [
            ("Humility",
             "God asks a young woman of Nazareth for her consent to become man. "
             "Mary listens, asks, and gives herself completely to his word. "
             "Let us ask for a heart ready to say yes to whatever God wills."),
            ("Love of neighbor",
             "Mary, carrying Jesus in her womb, sets out in haste to serve her cousin. "
             "Her visit fills Elizabeth and the child she is expecting with joy. "
             "Let us ask to bring Christ to others through simple acts of service."),
            ("Poverty of spirit",
             "The Son of God is born in the poverty of a manger. "
             "The first to adore him are simple shepherds. "
             "Let us ask for a heart free of attachments, one that knows how to make room for Jesus."),
            ("Obedience and purity",
             "Mary and Joseph fulfill the law and offer the Child in the temple. "
             "Simeon recognizes in him the light of the nations and foretells a sword of sorrow for Mary. "
             "Let us ask to offer our lives to God with faithfulness and trust."),
            ("Seeking God in all things",
             "After three days of anguish, Mary and Joseph find Jesus in the temple. "
             "He reminds them that he must be about his Father's business. "
             "Let us ask to seek Jesus always, even when it seems we have lost him."),
        ],
        "luminosos": [
            ("Faithfulness to our baptismal promises",
             "Jesus, who has no sin, stands in line with sinners at the Jordan. "
             "Heaven opens and the Father proclaims him his beloved Son. "
             "Let us ask to live as children of God, faithful to our baptism."),
            ("Trust in Jesus through Mary",
             "At Cana, Mary notices the couple's need before anyone else. "
             "Her advice is still the same: do whatever he tells you. "
             "Let us ask to entrust our needs to Jesus through his Mother."),
            ("Conversion of heart",
             "Jesus proclaims that the Kingdom of God is at hand and calls us to conversion. "
             "His mercy welcomes everyone who returns to him. "
             "Let us ask for a repentant heart that believes in the Gospel."),
            ("Desire for holiness",
             "On the mountain, Jesus lets his disciples see the glory of God. "
             "The Father asks us to listen to his beloved Son. "
             "Let us ask to let his light transform us in prayer."),
            ("Adoration and love of the Eucharist",
             "At the Last Supper, Jesus gives himself in the bread and the wine. "
             "He remains with us forever in the Eucharist. "
             "Let us ask to receive him with faith and adore him with love."),
        ],
        "dolorosos": [
            ("Conformity to the will of God",
             "In Gethsemane, Jesus feels anguish at the approaching passion. "
             "He prays insistently and abandons himself into the Father's hands. "
             "Let us ask to accept God's will even in the hour of trial."),
            ("Mortification of the senses",
             "Jesus is scourged in silence for our sins. "
             "His wounds are the price of our healing. "
             "Let us ask for the grace to offer our sufferings united to his."),
            ("Humility and contempt for vanity",
             "The soldiers mock Jesus and crown him with thorns as a mock king. "
             "He, the true King, bears the humiliation with meekness. "
             "Let us ask for a humble heart that does not seek the glory of the world."),
            ("Patience in the crosses of each day",
             "Jesus carries the cross on the way to Calvary and falls beneath its weight. "
             "Simon of Cyrene helps him to carry it. "
             "Let us ask to bear our cross with patience and to help others carry theirs."),
            ("Forgiveness and final perseverance",
             "Nailed to the cross, Jesus forgives those who crucify him. "
             "He commends his spirit to the Father and gives us Mary as our Mother. "
             "Let us ask to know how to forgive and to persevere in his love to the end."),
        ],
        "gloriosos": [
            ("Faith",
             "On the third day the tomb is empty: Christ has conquered death. "
             "The women are the first to receive the great news. "
             "Let us ask for a living faith that joyfully proclaims that he lives."),
            ("Hope and longing for heaven",
             "Jesus ascends into heaven as his disciples look on. "
             "He does not leave us alone: he prepares a place for us and will come again. "
             "Let us ask to live with our eyes fixed on heaven and our feet on the ground."),
            ("The gifts of the Holy Spirit",
             "Gathered in prayer with Mary, the apostles receive the Holy Spirit. "
             "Their fear is turned into courage to proclaim Christ. "
             "Let us ask to be docile to the Spirit and to bear witness to our faith."),
            ("The grace of a happy death",
             "At the end of her earthly life, Mary is taken up body and soul into heaven. "
             "In her we see the destiny God prepares for his children. "
             "Let us ask to live in such a way that one day we may meet her in glory."),
            ("Trust in Mary's intercession",
             "Mary is crowned Queen of heaven and earth. "
             "Her queenship is service: she intercedes tirelessly for her children. "
             "Let us ask to turn to her with the trust of children turning to their Mother."),
        ],
    },
    "pt": {
        "gozosos": [
            ("A humildade",
             "Deus pede licença a uma jovem de Nazaré para se fazer homem. "
             "Maria escuta, pergunta e entrega-se por completo à sua palavra. "
             "Peçamos um coração disposto a dizer sim a tudo o que Deus quiser."),
            ("A caridade para com o próximo",
             "Maria, levando Jesus no seu seio, parte apressadamente para servir a sua prima. "
             "A sua visita enche de alegria Isabel e o menino que ela espera. "
             "Peçamos a graça de levar Cristo aos outros com gestos simples de serviço."),
            ("A pobreza de espírito",
             "O Filho de Deus nasce na pobreza de uma manjedoura. "
             "Os primeiros a adorá-lo são uns pastores simples. "
             "Peçamos um coração livre de apegos, que saiba dar lugar a Jesus."),
            ("A obediência e a pureza",
             "Maria e José cumprem a lei e oferecem o Menino no templo. "
             "Simeão reconhece nele a luz das nações e anuncia a Maria uma espada de dor. "
             "Peçamos a graça de oferecer a Deus a nossa vida com fidelidade e confiança."),
            ("A busca de Deus em todas as coisas",
             "Depois de três dias de angústia, Maria e José encontram Jesus no templo. "
             "Ele recorda-lhes que deve ocupar-se das coisas de seu Pai. "
             "Peçamos a graça de procurar sempre Jesus, mesmo quando parece que o perdemos."),
        ],
        "luminosos": [
            ("A fidelidade às promessas do batismo",
             "Jesus, que não tem pecado, põe-se na fila dos pecadores no Jordão. "
             "O céu abre-se e o Pai proclama-o seu Filho amado. "
             "Peçamos a graça de viver como filhos de Deus, fiéis ao nosso batismo."),
            ("A confiança em Jesus por meio de Maria",
             "Em Caná, Maria dá-se conta da necessidade dos noivos antes de todos. "
             "O seu conselho continua a ser o mesmo: fazei o que Ele vos disser. "
             "Peçamos a graça de confiar as nossas necessidades a Jesus por meio de sua Mãe."),
            ("A conversão do coração",
             "Jesus anuncia que o Reino de Deus está próximo e chama à conversão. "
             "A sua misericórdia acolhe todo aquele que volta para Ele. "
             "Peçamos um coração arrependido que creia no Evangelho."),
            ("O desejo de santidade",
             "No monte, Jesus deixa os seus discípulos ver a glória de Deus. "
             "O Pai pede-nos que escutemos o seu Filho amado. "
             "Peçamos a graça de nos deixarmos transformar pela sua luz na oração."),
            ("A adoração e o amor à Eucaristia",
             "Na última ceia, Jesus entrega-se a si mesmo no pão e no vinho. "
             "Permanece para sempre entre nós na Eucaristia. "
             "Peçamos a graça de recebê-lo com fé e adorá-lo com amor."),
        ],
        "dolorosos": [
            ("A conformidade com a vontade de Deus",
             "No Horto das Oliveiras, Jesus sente angústia diante da paixão que se aproxima. "
             "Reza com insistência e abandona-se nas mãos do Pai. "
             "Peçamos a graça de aceitar a vontade de Deus também na hora da provação."),
            ("A mortificação dos sentidos",
             "Jesus é flagelado em silêncio pelos nossos pecados. "
             "As suas feridas são o preço da nossa cura. "
             "Peçamos a graça de oferecer os nossos sofrimentos unidos aos seus."),
            ("A humildade e o desprezo da vaidade",
             "Os soldados escarnecem de Jesus e coroam-no de espinhos como a um rei de escárnio. "
             "Ele, verdadeiro Rei, suporta a humilhação com mansidão. "
             "Peçamos um coração humilde que não procure a glória do mundo."),
            ("A paciência nas cruzes de cada dia",
             "Jesus carrega a cruz a caminho do Calvário e cai sob o seu peso. "
             "Simão de Cirene ajuda-o a levá-la. "
             "Peçamos a graça de levar com paciência a nossa cruz e de ajudar os outros a levar a sua."),
            ("O perdão e a perseverança final",
             "Pregado na cruz, Jesus perdoa aos que o crucificam. "
             "Entrega o seu espírito ao Pai e dá-nos Maria como Mãe. "
             "Peçamos a graça de saber perdoar e de perseverar no seu amor até o fim."),
        ],
        "gloriosos": [
            ("A fé",
             "Ao terceiro dia, o sepulcro está vazio: Cristo venceu a morte. "
             "As mulheres são as primeiras a receber a grande notícia. "
             "Peçamos uma fé viva que anuncie com alegria que Ele vive."),
            ("A esperança e o desejo do céu",
             "Jesus sobe ao céu diante do olhar dos seus discípulos. "
             "Não nos deixa sós: prepara-nos um lugar e voltará. "
             "Peçamos a graça de viver com o olhar posto no céu e os pés na terra."),
            ("Os dons do Espírito Santo",
             "Reunidos em oração com Maria, os apóstolos recebem o Espírito Santo. "
             "O medo transforma-se em coragem para anunciar Cristo. "
             "Peçamos a graça de ser dóceis ao Espírito e de dar testemunho da nossa fé."),
            ("A graça de uma boa morte",
             "Terminada a sua vida na terra, Maria é levada em corpo e alma para o céu. "
             "Nela vemos o destino que Deus prepara para os seus filhos. "
             "Peçamos a graça de viver de tal modo que um dia nos encontremos com ela na glória."),
            ("A confiança na intercessão de Maria",
             "Maria é coroada Rainha do céu e da terra. "
             "A sua realeza é serviço: intercede sem descanso pelos seus filhos. "
             "Peçamos a graça de recorrer a ela com a confiança de quem recorre à sua Mãe."),
        ],
    },
    "it": {
        "gozosos": [
            ("L'umiltà",
             "Dio chiede il consenso a una giovane di Nazaret per farsi uomo. "
             "Maria ascolta, domanda e si affida completamente alla sua parola. "
             "Chiediamo un cuore pronto a dire sì a tutto ciò che Dio vuole."),
            ("La carità verso il prossimo",
             "Maria, portando Gesù nel suo grembo, parte in fretta per servire sua cugina. "
             "La sua visita riempie di gioia Elisabetta e il bambino che attende. "
             "Chiediamo di portare Cristo agli altri con semplici gesti di servizio."),
            ("La povertà di spirito",
             "Il Figlio di Dio nasce nella povertà di una mangiatoia. "
             "I primi ad adorarlo sono dei semplici pastori. "
             "Chiediamo un cuore libero da attaccamenti, che sappia fare spazio a Gesù."),
            ("L'obbedienza e la purezza",
             "Maria e Giuseppe adempiono la legge e offrono il Bambino nel tempio. "
             "Simeone riconosce in lui la luce delle genti e annuncia a Maria una spada di dolore. "
             "Chiediamo di offrire a Dio la nostra vita con fedeltà e fiducia."),
            ("La ricerca di Dio in tutte le cose",
             "Dopo tre giorni di angoscia, Maria e Giuseppe trovano Gesù nel tempio. "
             "Egli ricorda loro che deve occuparsi delle cose del Padre suo. "
             "Chiediamo di cercare sempre Gesù, anche quando ci sembra di averlo perduto."),
        ],
        "luminosos": [
            ("La fedeltà alle promesse battesimali",
             "Gesù, che non ha peccato, si mette in fila con i peccatori al Giordano. "
             "Il cielo si apre e il Padre lo proclama suo Figlio amato. "
             "Chiediamo di vivere come figli di Dio, fedeli al nostro battesimo."),
            ("La fiducia in Gesù per mezzo di Maria",
             "A Cana, Maria si accorge prima di tutti del bisogno degli sposi. "
             "Il suo consiglio è sempre lo stesso: fate quello che vi dirà. "
             "Chiediamo di affidare le nostre necessità a Gesù per mezzo di sua Madre."),
            ("La conversione del cuore",
             "Gesù annuncia che il Regno di Dio è vicino e chiama alla conversione. "
             "La sua misericordia accoglie chiunque ritorna a lui. "
             "Chiediamo un cuore pentito che creda al Vangelo."),
            ("Il desiderio di santità",
             "Sul monte, Gesù lascia vedere ai suoi discepoli la gloria di Dio. "
             "Il Padre ci chiede di ascoltare il suo Figlio amato. "
             "Chiediamo di lasciarci trasformare dalla sua luce nella preghiera."),
            ("L'adorazione e l'amore per l'Eucaristia",
             "Nell'ultima cena, Gesù dona se stesso nel pane e nel vino. "
             "Rimane con noi per sempre nell'Eucaristia. "
             "Chiediamo di riceverlo con fede e di adorarlo con amore."),
        ],
        "dolorosos": [
            ("La conformità alla volontà di Dio",
             "Nel Getsemani, Gesù prova angoscia davanti alla passione che si avvicina. "
             "Prega con insistenza e si abbandona nelle mani del Padre. "
             "Chiediamo di accettare la volontà di Dio anche nell'ora della prova."),
            ("La mortificazione dei sensi",
             "Gesù è flagellato in silenzio per i nostri peccati. "
             "Le sue piaghe sono il prezzo della nostra guarigione. "
             "Chiediamo la grazia di offrire le nostre sofferenze unite alle sue."),
            ("L'umiltà e il disprezzo della vanità",
             "I soldati deridono Gesù e lo coronano di spine come un re da burla. "
             "Egli, vero Re, sopporta l'umiliazione con mitezza. "
             "Chiediamo un cuore umile che non cerchi la gloria del mondo."),
            ("La pazienza nelle croci di ogni giorno",
             "Gesù porta la croce verso il Calvario e cade sotto il suo peso. "
             "Simone di Cirene lo aiuta a portarla. "
             "Chiediamo di portare con pazienza la nostra croce e di aiutare gli altri a portare la loro."),
            ("Il perdono e la perseveranza finale",
             "Inchiodato alla croce, Gesù perdona coloro che lo crocifiggono. "
             "Consegna il suo spirito al Padre e ci dona Maria come Madre. "
             "Chiediamo di saper perdonare e di perseverare nel suo amore fino alla fine."),
        ],
        "gloriosos": [
            ("La fede",
             "Il terzo giorno il sepolcro è vuoto: Cristo ha vinto la morte. "
             "Le donne sono le prime a ricevere il grande annuncio. "
             "Chiediamo una fede viva che annunci con gioia che egli vive."),
            ("La speranza e il desiderio del cielo",
             "Gesù sale al cielo sotto lo sguardo dei suoi discepoli. "
             "Non ci lascia soli: ci prepara un posto e tornerà. "
             "Chiediamo di vivere con lo sguardo rivolto al cielo e i piedi per terra."),
            ("I doni dello Spirito Santo",
             "Riuniti in preghiera con Maria, gli apostoli ricevono lo Spirito Santo. "
             "La paura si trasforma in coraggio per annunciare Cristo. "
             "Chiediamo di essere docili allo Spirito e di testimoniare la nostra fede."),
            ("La grazia di una buona morte",
             "Al termine della sua vita terrena, Maria è assunta in corpo e anima al cielo. "
             "In lei vediamo il destino che Dio prepara per i suoi figli. "
             "Chiediamo di vivere in modo da incontrarla un giorno nella gloria."),
            ("La fiducia nell'intercessione di Maria",
             "Maria è incoronata Regina del cielo e della terra. "
             "La sua regalità è servizio: intercede senza sosta per i suoi figli. "
             "Chiediamo di ricorrere a lei con la fiducia di chi si rivolge alla propria Madre."),
        ],
    },
    "la": {
        "gozosos": [
            ("Humilitas",
             "Deus a virgine Nazarethana consensum petit ut homo fiat. "
             "Maria audit, interrogat et verbo eius se totam tradit. "
             "Petamus cor paratum ut omni Dei voluntati assentiat."),
            ("Caritas erga proximum",
             "Maria, Iesum in utero gestans, cum festinatione proficiscitur ut cognatae suae serviat. "
             "Visitatio eius Elisabeth et infantem quem exspectat gaudio replet. "
             "Petamus ut Christum ad alios humilibus ministeriis feramus."),
            ("Paupertas spiritus",
             "Filius Dei in paupertate praesepii nascitur. "
             "Primi eum adorant pastores simplices. "
             "Petamus cor ab omni inordinato affectu liberum, quod Iesu locum parare sciat."),
            ("Oboedientia et puritas",
             "Maria et Ioseph legem implent et Puerum in templo offerunt. "
             "Simeon in eo lumen gentium agnoscit et Mariae gladium doloris praenuntiat. "
             "Petamus ut vitam nostram Deo fideliter et confidenter offeramus."),
            ("Deum in omnibus quaerere",
             "Post triduum angoris Maria et Ioseph Iesum in templo inveniunt. "
             "Ipse eos monet se in his quae Patris sui sunt esse oportere. "
             "Petamus ut Iesum semper quaeramus, etiam cum eum amisisse videmur."),
        ],
        "luminosos": [
            ("Fidelitas promissionibus baptismatis",
             "Iesus, qui peccatum non habet, inter peccatores ad Iordanem consistit. "
             "Caelum aperitur et Pater eum Filium suum dilectum proclamat. "
             "Petamus ut tamquam filii Dei vivamus, baptismati nostro fideles."),
            ("Fiducia in Iesum per Mariam",
             "In Cana Maria ante omnes sponsorum necessitatem animadvertit. "
             "Eius consilium idem manet: quodcumque dixerit vobis, facite. "
             "Petamus ut necessitates nostras Iesu per Matrem eius committamus."),
            ("Conversio cordis",
             "Iesus regnum Dei appropinquare nuntiat et ad conversionem vocat. "
             "Misericordia eius omnem qui ad eum revertitur suscipit. "
             "Petamus cor paenitens quod Evangelio credat."),
            ("Desiderium sanctitatis",
             "In monte Iesus discipulis suis gloriam Dei ostendit. "
             "Pater nos iubet Filium suum dilectum audire. "
             "Petamus ut in oratione luce eius transformemur."),
            ("Adoratio et amor Eucharistiae",
             "In ultima cena Iesus se ipsum in pane et vino tradit. "
             "In Eucharistia nobiscum in perpetuum manet. "
             "Petamus ut eum fide suscipiamus et amore adoremus."),
        ],
        "dolorosos": [
            ("Conformitas voluntati Dei",
             "In Gethsemani Iesus, passione appropinquante, angore premitur. "
             "Instanter orat et se in manus Patris tradit. "
             "Petamus ut voluntatem Dei etiam in hora probationis accipiamus."),
            ("Mortificatio sensuum",
             "Iesus pro peccatis nostris in silentio flagellatur. "
             "Vulnera eius pretium sunt sanationis nostrae. "
             "Petamus gratiam dolores nostros cum doloribus eius coniunctos offerendi."),
            ("Humilitas et vanitatis contemptus",
             "Milites Iesu illudunt eumque spinis coronant tamquam regem ludibrii. "
             "Ipse, verus Rex, contumeliam mansuete sustinet. "
             "Petamus cor humile quod gloriam mundi non quaerat."),
            ("Patientia in cotidianis crucibus",
             "Iesus crucem ad Calvariae locum baiulat et sub eius pondere cadit. "
             "Simon Cyrenaeus eum ad crucem portandam adiuvat. "
             "Petamus ut crucem nostram patienter feramus et alios in sua ferenda adiuvemus."),
            ("Venia et perseverantia finalis",
             "Cruci affixus, Iesus crucifixoribus suis ignoscit. "
             "Spiritum suum Patri commendat et Mariam nobis Matrem dat. "
             "Petamus ut ignoscere sciamus et in eius amore usque ad finem perseveremus."),
        ],
        "gloriosos": [
            ("Fides",
             "Tertia die sepulcrum vacuum est: Christus mortem vicit. "
             "Mulieres primae magnum nuntium accipiunt. "
             "Petamus fidem vivam quae cum gaudio eum vivere annuntiet."),
            ("Spes et desiderium caeli",
             "Iesus, videntibus discipulis suis, in caelum ascendit. "
             "Non nos solos relinquit: locum nobis parat et iterum veniet. "
             "Petamus ut oculis in caelum defixis et pedibus in terra vivamus."),
            ("Dona Spiritus Sancti",
             "Apostoli, cum Maria in oratione congregati, Spiritum Sanctum accipiunt. "
             "Timor in fortitudinem ad Christum annuntiandum convertitur. "
             "Petamus ut Spiritui dociles simus et fidei nostrae testimonium reddamus."),
            ("Gratia bonae mortis",
             "Expleto terrestris vitae cursu, Maria corpore et anima in caelum assumitur. "
             "In ea videmus quod Deus filiis suis praeparat. "
             "Petamus ut ita vivamus ut eam aliquando in gloria conveniamus."),
            ("Fiducia in Mariae intercessione",
             "Maria Regina caeli et terrae coronatur. "
             "Eius regnum est servitium: sine intermissione pro filiis suis intercedit. "
             "Petamus ut ad eam confugiamus cum fiducia filiorum ad Matrem confugientium."),
        ],
    },
}

# Scripture citations: the book abbreviations of each language, by the
# Spanish abbreviation of MYSTERIES, and the separator between chapter and
# verse. Spanish keeps its own abbreviations.
BOOK_ABBR = {
    "en": {"Mt": "Mt", "Mc": "Mk", "Lc": "Lk", "Jn": "Jn", "Hch": "Acts", "Ap": "Apoc"},
    "pt": {"Mt": "Mt", "Mc": "Mc", "Lc": "Lc", "Jn": "Jo", "Hch": "At", "Ap": "Ap"},
    "it": {"Mt": "Mt", "Mc": "Mc", "Lc": "Lc", "Jn": "Gv", "Hch": "At", "Ap": "Ap"},
    "la": {"Mt": "Mt", "Mc": "Mc", "Lc": "Lc", "Jn": "Io", "Hch": "Act", "Ap": "Ap"},
}
VERSE_SEPARATOR = {
    "es": ", ",
    "en": ":",
    "pt": ",",
    "it": ",",
    "la": ", ",
}

# Douay-Rheims (Challoner revision), Project Gutenberg eBook #1581: chapters
# are headed "<Book> Chapter <n>", verses are paragraphs "<chapter>:<verse>. ".
DOUAY_RHEIMS_TEXT = "https://www.gutenberg.org/cache/epub/1581/pg1581.txt"
DOUAY_RHEIMS_PAGE = "https://www.gutenberg.org/ebooks/1581"
DOUAY_RHEIMS_BOOKS = {"Mt": "Matthew", "Mc": "Mark", "Lc": "Luke", "Jn": "John",
                      "Hch": "Acts", "Ap": "Apocalypse"}

# Martini Bible on parolaviva.art: one page per chapter.
MARTINI_PAGE = "https://parolaviva.art/bibbia/%s/%d/"
MARTINI_BOOKS = {"Mt": "mt", "Mc": "mc", "Lc": "lc", "Jn": "gv", "Hch": "at", "Ap": "ap"}

# Clementine Vulgate on Latin Wikisource: one page per book, chapters headed
# "==Caput <n>==" and verses numbered <sup>n</sup>.
VULGATE_PAGE = "https://la.wikisource.org/wiki/Vulgata_Clementina/"
VULGATE_BOOKS = {
    "Mt": "Evangelium_Secundum_Matthaeum",
    "Mc": "Evangelium_Secundum_Marcum",
    "Lc": "Evangelium_Secundum_Lucam",
    "Jn": "Evangelium_Secundum_Joannem",
    "Hch": "Acta_Apostolorum",
    "Ap": "Apocalypsis",
}

# Almeida, Edição Revista e Corrigida (Lisbon, 1911 reprint of the 1900
# edition), Project Gutenberg eBook #62383. Its HTML edition has one paragraph
# per verse, <p id="<Book><chapter>-<verse>">, opened by the verse number (by
# the chapter number for verse 1). Footnote and alternative-reading anchors
# are links of class "fnanchor"; page numbers are spans of class "pagenum".
ALMEIDA_HTML = "https://www.gutenberg.org/cache/epub/62383/pg62383-images.html"
ALMEIDA_PAGE = "https://www.gutenberg.org/ebooks/62383"
ALMEIDA_BOOKS = {"Mt": "Mat", "Mc": "Mar", "Lc": "Luc", "Jn": "Joao", "Hch": "Act", "Ap": "Apo"}
ALMEIDA_TRANSLATION = "Almeida, Revista e Corrigida (ed. 1911)"


class SourceError(Exception):
    pass


class MissingVerse(SourceError):
    """A verse of a fragment has no text in its source; the message is its citation."""


def fetch(url, cache_dir, name):
    path = os.path.join(cache_dir, name)
    if not os.path.exists(path):
        part = path + ".part"
        # Download to a temporary name so a failed transfer never poisons the cache.
        subprocess.run(
            ["curl", "-sSfL", "--retry", "5", "--retry-all-errors", "--retry-delay", "2",
             "-A", USER_AGENT, "-o", part, url],
            check=True,
        )
        os.replace(part, path)
        # Be gentle with the hosts (Wikimedia answers bursts with HTTP 429).
        time.sleep(1)
    with open(path, "rb") as fh:
        return fh.read()


def html_to_text(fragment):
    """Convert a small HTML fragment to text: <br> joins lines, </p> breaks paragraphs."""
    s = re.sub(r"<br\s*/?>", " ", fragment, flags=re.I)
    s = re.sub(r"</p\s*>", "\n", s, flags=re.I)
    s = re.sub(r"<[^>]+>", "", s)
    s = html.unescape(s).replace("\xa0", " ")
    paragraphs = []
    for para in s.split("\n"):
        para = re.sub(r"\s+", " ", para).strip()
        if para:
            paragraphs.append(para)
    return "\n".join(paragraphs)


def html_to_lines(page):
    """The lines of an HTML page: <br> and the tags of blocks break lines."""
    s = re.sub(r"<br\s*/?>|</?(?:p|div|td|tr|li|h\d)(?:\s[^>]*)?>", "\n", page, flags=re.I)
    s = re.sub(r"<[^>]+>", "", s)
    s = html.unescape(s).replace("\xa0", " ")
    lines = []
    for line in s.split("\n"):
        line = re.sub(r"\s+", " ", line).strip()
        if line:
            lines.append(line)
    return lines


def normalize_heading(text):
    return re.sub(r"\s+", " ", text).strip().rstrip(",.").lower()


def tidy(text):
    """Fix two typing slips of the Compendium pages: a doubled full stop, and
    an acute accent typed after "æ" instead of the accented letter."""
    text = re.sub(r"(?<!\.)\.\.(?!\.)", ".", text)
    return text.replace("æ´", "ǽ").replace("Æ´", "Ǽ")


def vatican_cells(page):
    """Yield (heading, body_text) for every bold-headed section of the table cells.

    A cell may hold several prayers (e.g. both creeds), each introduced by a
    bold heading, so the body of a heading stops at the next bold heading.
    """
    for cell in re.findall(r"<td[^>]*>(.*?)</td>", page, flags=re.S | re.I):
        heads = list(re.finditer(r"<b>(.*?)</b>", cell, flags=re.S | re.I))
        for k, m in enumerate(heads):
            end = heads[k + 1].start() if k + 1 < len(heads) else len(cell)
            heading = html_to_text(m.group(1))
            body = html_to_text(cell[m.end():end])
            if heading:
                yield heading, body


def vatican_bodies(page):
    """{normalized heading: body} of the Compendium page, first body of each heading."""
    bodies = {}
    for heading, body in vatican_cells(page):
        bodies.setdefault(normalize_heading(heading), body)
    return bodies


def compendium_prayers(bodies, lang, source):
    """The prayers of PRAYERS[lang] from the Compendium bodies."""
    prayers = {}
    for spec in PRAYERS[lang]:
        pid, title, heading = spec[:3]
        options = spec[3] if len(spec) > 3 else {}
        body = bodies.get(normalize_heading(heading))
        if not body:
            raise SourceError("prayer not found in Vatican appendix: " + heading)
        if "variant" in options:
            lines = body.split("\n")
            marks = [k for k, line in enumerate(lines)
                     if normalize_heading(line) == normalize_heading(options["variant"])]
            if not marks or marks[0] + 1 >= len(lines):
                raise SourceError("variant %s not found for %s" % (options["variant"], heading))
            body = lines[marks[0] + 1]
        if "until" in options:
            end = body.find(options["until"])
            if end < 0:
                raise SourceError("end marker %s not found for %s" % (options["until"], heading))
            body = body[:end].rstrip()
        if lang != "es":
            body = tidy(body)
        prayers[pid] = {"title": title, "text": body, "source": source}
    return prayers


def parse_vatican(page):
    bodies = vatican_bodies(page)
    prayers = compendium_prayers(bodies, "es", VATICAN_URL + "#" + COMPENDIUM["es"][1])
    rosary = bodies.get("rosario")
    if not rosary:
        raise SourceError("Rosario cell not found in Vatican appendix")
    return prayers, parse_mystery_titles(rosary)


def parse_mystery_titles(text):
    titles = {}
    current = None
    for m in re.finditer(r"Misterios (gozosos|luminosos|dolorosos|gloriosos)|(\d)\. ([^.]+)\.", text):
        if m.group(1):
            current = m.group(1)
            titles[current] = []
        elif current and len(titles[current]) < 5:
            titles[current].append(m.group(3).strip())
    for set_id in SET_ORDER:
        if len(titles.get(set_id, [])) != 5:
            raise SourceError("expected 5 mystery titles for " + set_id)
    return titles


def parse_titles(page, headings, layout):
    """{set_id: five titles} from the Rosary section of a Compendium page.

    Each set heading of `headings` (in SET_ORDER) is followed by a line in
    parentheses (the days of the week) and then by the titles, one per line
    or ended by a full stop (a title may then wrap onto the next line).
    """
    lines = html_to_lines(page)
    keys = [normalize_heading(h) for h in headings]
    norm = [normalize_heading(line) for line in lines]
    for first in [k for k, n in enumerate(norm) if n == keys[0]]:
        titles, pos = {}, first
        for k, set_id in enumerate(SET_ORDER):
            # The section of a set ends at the next set heading; the last
            # one is cut after its five titles.
            end = min(pos + 40, len(lines))
            if k + 1 < len(keys):
                end = next((j for j in range(pos + 1, end) if norm[j] == keys[k + 1]), None)
                if end is None:
                    break
            body = [line for line in lines[pos + 1:end]
                    if not (line.startswith("(") and line.endswith(")"))]
            if layout == "sentences":
                items = [t.strip()[:-1].strip() for t in re.findall(r"[^.]+\.", " ".join(body))]
            else:
                items = body
            if len(items) < 5:
                break
            titles[set_id] = [tidy(t) for t in items[:5]]
            pos = end
        if len(titles) == len(SET_ORDER):
            return titles
    raise SourceError("expected 5 mystery titles for each set")


def parse_fatima(page, marker, title, source):
    for para in re.findall(r"<p(?:\s[^>]*)?>(.*?)</p>", page, flags=re.S | re.I):
        if marker in para:
            return {
                "title": title,
                "text": html_to_text(para + "</p>"),
                "source": source,
            }
    raise SourceError("Fatima prayer not found on " + source)


# --- Wikisource -----------------------------------------------------------

def api_get(params, cache_dir, name):
    url = WIKISOURCE_API + "?" + urllib.parse.urlencode(params)
    return json.loads(fetch(url, cache_dir, name).decode("utf-8"))


def page_contents(titles, cache_dir, tag):
    """Return {title: wikitext} for up to 50 titles per request."""
    out = {}
    for start in range(0, len(titles), 50):
        chunk = titles[start:start + 50]
        data = api_get({
            "action": "query", "prop": "revisions", "rvprop": "content",
            "rvslots": "main", "format": "json", "formatversion": "2",
            "titles": "|".join(chunk),
        }, cache_dir, "%s_%03d.json" % (tag, start))
        for page in data["query"]["pages"]:
            if "revisions" in page:
                out[page["title"]] = page["revisions"][0]["slots"]["main"]["content"]
    return out


def split_params(inner):
    """Split template inner text on top-level pipes."""
    params, depth, buf, i = [], 0, [], 0
    while i < len(inner):
        two = inner[i:i + 2]
        if two in ("{{", "[["):
            depth += 1
            buf.append(two)
            i += 2
            continue
        if two in ("}}", "]]"):
            depth -= 1
            buf.append(two)
            i += 2
            continue
        if inner[i] == "|" and depth == 0:
            params.append("".join(buf))
            buf = []
        else:
            buf.append(inner[i])
        i += 1
    params.append("".join(buf))
    return params


SKIP_TEMPLATES = {"np", "línea", "línea adornada", "listaref", "cp", "biblia", "c"}
PASS_TEMPLATES = {"menor", "grande", "x-grande", "xx-grande", "may"}


def expand_templates(text, unknown):
    out, i = [], 0
    while i < len(text):
        if text.startswith("{{", i):
            depth, j = 0, i
            while j < len(text):
                if text.startswith("{{", j):
                    depth += 1
                    j += 2
                elif text.startswith("}}", j):
                    depth -= 1
                    j += 2
                    if depth == 0:
                        break
                else:
                    j += 1
            inner = text[i + 2:j - 2]
            params = split_params(inner)
            name = params[0].strip().lower()
            args = params[1:]
            if name == "vers" and len(args) >= 2:
                out.append("\x00%s:%s\x00" % (args[0].strip(), args[1].strip()))
            elif name == "corr" and len(args) >= 2:
                out.append(expand_templates(args[1], unknown))
            elif name == "guion":
                # Word split across pages: the second parameter holds the
                # whole word on the second page and is empty on the first.
                if len(args) >= 2:
                    out.append(expand_templates(args[1], unknown))
            elif name == "dicc lsb" and len(args) >= 2:
                out.append(expand_templates(args[1], unknown))
            elif name == "sc":
                body = args[0] if args else ""
                # Chapter summaries are wrapped as {{sc|{{menor|...}}}}.
                if not body.lstrip().lower().startswith("{{menor"):
                    out.append(expand_templates(body, unknown))
            elif name in SKIP_TEMPLATES:
                pass
            elif name in PASS_TEMPLATES:
                out.append(expand_templates(args[0] if args else "", unknown))
            else:
                unknown.add(name)
                if args:
                    out.append(expand_templates(args[-1], unknown))
            i = j
        else:
            out.append(text[i])
            i += 1
    return "".join(out)


def clean_page(wikitext, unknown):
    s = re.sub(r"<noinclude>.*?</noinclude>", "", wikitext, flags=re.S)
    s = re.sub(r"<ref[^>]*/>", "", s)
    s = re.sub(r"<ref[^>]*>.*?</ref>", "", s, flags=re.S)
    s = re.sub(r"<section[^>]*/>", "", s)
    s = expand_templates(s, unknown)
    s = re.sub(r"\[\[(?:[^|\]]*\|)?([^\]]*)\]\]", r"\1", s)
    s = s.replace("'''", "").replace("''", "")
    s = re.sub(r"<[^>]+>", " ", s)
    return s.strip()


def join_pages(bodies):
    text = ""
    for body in bodies:
        if re.search(r"\w-$", text) and body:
            text = text[:-1] + body
        else:
            text = text + "\n" + body
    return text


def book_verses(abbr, cache_dir, unknown):
    title = BOOKS[abbr]
    raw = fetch(WIKISOURCE_PAGE + urllib.parse.quote(title.replace(" ", "_")) + "?action=raw",
                cache_dir, "book_%s.txt" % abbr).decode("utf-8")
    m = re.search(r'<pages index="([^"]+)" from=(\d+) to=(\d+)', raw)
    if not m:
        raise SourceError("no page range for " + title)
    index, first, last = m.group(1), int(m.group(2)), int(m.group(3))
    titles = ["Página:%s/%d" % (index, n) for n in range(first, last + 1)]
    contents = page_contents(titles, cache_dir, "pages_" + abbr)
    bodies = [clean_page(contents[t], unknown) for t in titles if t in contents]
    text = join_pages(bodies)
    verses = {}
    parts = re.split(r"\x00(\d+):(\d+)\x00", text)
    for k in range(1, len(parts), 3):
        chapter, verse, body = int(parts[k]), int(parts[k + 1]), parts[k + 2]
        body = re.sub(r"\s+", " ", body).strip().strip("—").strip()
        # Footnote anchors removed above can leave a space before punctuation.
        body = re.sub(r"\s+([.,;:?!»)])", r"\1", body)
        verses.setdefault((chapter, verse), body)
    return verses, WIKISOURCE_PAGE + urllib.parse.quote(title.replace(" ", "_"), safe="/()")


# --- Other Bibles ---------------------------------------------------------

def clean_verse(text):
    """Collapse whitespace and drop the space some editions put before punctuation."""
    text = re.sub(r"\s+", " ", text).strip()
    return re.sub(r"\s+([.,;:?!»)])", r"\1", text)


def douay_rheims_verses(cache_dir):
    """{book: {(chapter, verse): text}} of the books in DOUAY_RHEIMS_BOOKS."""
    text = fetch(DOUAY_RHEIMS_TEXT, cache_dir, "douay_rheims.txt").decode("utf-8")
    abbr_of = {name: abbr for abbr, name in DOUAY_RHEIMS_BOOKS.items()}
    books, book = {abbr: {} for abbr in DOUAY_RHEIMS_BOOKS}, None
    for para in re.split(r"\n[ \t\r]*\n", text.replace("\r\n", "\n")):
        para = " ".join(para.split())
        m = re.fullmatch(r"((?:\d )?[A-Z][A-Za-z ]*) Chapter \d+", para)
        if m:
            # "1 John Chapter 1" and the other books are not in the table.
            book = abbr_of.get(m.group(1))
            continue
        m = re.match(r"(\d+):(\d+)\. (.+)", para)
        if book and m:
            books[book].setdefault((int(m.group(1)), int(m.group(2))), clean_verse(m.group(3)))
    return books


def martini_chapter(book, chapter, cache_dir):
    """({(chapter, verse): text}, url) of a chapter of the Martini Bible."""
    url = MARTINI_PAGE % (MARTINI_BOOKS[book], chapter)
    page = fetch(url, cache_dir, "martini_%s_%d.html" % (book, chapter)).decode("utf-8")
    verses = {}
    for m in re.finditer(r'<span class="num-versetto">(\d+)</span>'
                         r'<span class="testo-versetto">(.*?)</span>', page, flags=re.S):
        verses.setdefault((chapter, int(m.group(1))), clean_verse(html_to_text(m.group(2))))
    return verses, url


def vulgate_book(book, cache_dir):
    """({(chapter, verse): text}, url) of a book of the Clementine Vulgate."""
    url = VULGATE_PAGE + VULGATE_BOOKS[book]
    raw = fetch(url + "?action=raw", cache_dir, "vulgate_%s.txt" % book).decode("utf-8")
    verses = {}
    chapters = re.split(r"^==\s*Caput (\d+)\s*==\s*$", raw, flags=re.M)
    for k in range(1, len(chapters), 2):
        chapter = int(chapters[k])
        parts = re.split(r"<sup>(\d+)</sup>", chapters[k + 1])
        for j in range(1, len(parts), 2):
            body = re.sub(r"<[^>]+>", " ", parts[j + 1])
            verses.setdefault((chapter, int(parts[j])), clean_verse(body))
    return verses, url


def parse_almeida(page):
    """{book: {(chapter, verse): text}} of the books in ALMEIDA_BOOKS, from the
    HTML edition of the Almeida Bible."""
    abbr_of = {name: abbr for abbr, name in ALMEIDA_BOOKS.items()}
    books = {abbr: {} for abbr in ALMEIDA_BOOKS}
    pattern = r'<p id="(%s)(\d+)-(\d+)">(.*?)</p>' % "|".join(ALMEIDA_BOOKS.values())
    for m in re.finditer(pattern, page, flags=re.S):
        chapter, verse = int(m.group(2)), int(m.group(3))
        body = re.sub(r'<span class="pagenum">.*?</span>', " ", m.group(4), flags=re.S)
        body = re.sub(r'<a [^>]*class="fnanchor[^"]*"[^>]*>.*?</a>', " ", body, flags=re.S)
        body = re.sub(r'<span class="first">\d+</span>', " ", body)
        text = re.sub(r"^%d " % verse, "", clean_verse(html_to_text(body)))
        books[abbr_of[m.group(1)]].setdefault((chapter, verse), text)
    return books


def almeida_verses(cache_dir):
    """{book: {(chapter, verse): text}} of the Almeida Bible."""
    return parse_almeida(fetch(ALMEIDA_HTML, cache_dir, "almeida.html").decode("utf-8"))


def format_passage(book, chapter, v1, v2, lang):
    """A citation such as "Lc 1, 30-31" (es), "Lk 1:30-31" (en) or "Gv 2,3" (it)."""
    abbr = BOOK_ABBR.get(lang, {}).get(book, book)
    sep = VERSE_SEPARATOR[lang]
    if v1 == v2:
        return "%s %d%s%d" % (abbr, chapter, sep, v1)
    return "%s %d%s%d-%d" % (abbr, chapter, sep, v1, v2)


def parse_reference(reference):
    """The passages [(book, chapter, v1, v2)] of a Spanish reference of MYSTERIES."""
    passages = []
    for part in reference.split("; "):
        m = re.fullmatch(r"(\w+) (\d+), (\d+)(?:-(\d+))?", part)
        if not m:
            raise ValueError("bad reference: " + reference)
        v1 = int(m.group(3))
        passages.append((m.group(1), int(m.group(2)), v1, int(m.group(4) or v1)))
    return passages


def build_fragment(spec, lookup, translation, lang):
    """The scripture of a mystery: the verses of `spec` joined with " […] ".

    `lookup(book, chapter)` returns ({(chapter, verse): text}, source url).
    Raises MissingVerse when a verse is missing.
    """
    pieces, sources, refs = [], [], []
    for book, chapter, v1, v2 in spec:
        verses, url = lookup(book, chapter)
        texts = []
        for v in range(v1, v2 + 1):
            t = verses.get((chapter, v))
            if not t:
                raise MissingVerse(format_passage(book, chapter, v, v, lang))
            texts.append(t)
        pieces.append(" ".join(texts))
        if url not in sources:
            sources.append(url)
        refs.append(format_passage(book, chapter, v1, v2, lang))
    text = " […] ".join(pieces)
    # Mark fragments that start or stop mid-sentence with an ellipsis.
    if text[:1].islower():
        text = "…" + text
    if text[-1:] in ",;:":
        text = text[:-1] + "…"
    return {
        "text": text,
        "citation": "; ".join(refs),
        "verbatim": True,
        "translation": translation,
        "source": " ".join(sources),
    }


# --- Lua output -----------------------------------------------------------

def lua_str(s):
    s = s.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n")
    return '"' + s + '"'


def emit(value, indent=0):
    pad = "    " * indent
    if isinstance(value, bool):
        return "true" if value else "false"
    if isinstance(value, int):
        return str(value)
    if isinstance(value, str):
        return lua_str(value)
    if isinstance(value, list):
        if not value:
            return "{}"
        items = [pad + "    " + emit(v, indent + 1) + "," for v in value]
        return "{\n" + "\n".join(items) + "\n" + pad + "}"
    if isinstance(value, dict):
        items = []
        for key in value:
            items.append("%s    %s = %s," % (pad, key, emit(value[key], indent + 1)))
        return "{\n" + "\n".join(items) + "\n" + pad + "}"
    raise TypeError(type(value))


PRAYER_ORDER = ["sign_of_cross", "creed", "our_father", "hail_mary", "glory_be", "fatima", "salve"]


def build_es(cache_dir):
    """Spanish content: returns (header, data) for content/es.lua."""
    vatican = fetch(VATICAN_URL, cache_dir, "vatican_compendio.html").decode("iso-8859-1")
    prayers, titles = parse_vatican(vatican)
    marker, title = FATIMA["es"][1:]
    prayers["fatima"] = parse_fatima(fetch(EWTN_FATIMA_URL, cache_dir, "ewtn_fatima.html").decode("utf-8"),
                                     marker, title, EWTN_FATIMA_URL)

    unknown, books = set(), {}

    def lookup(book, chapter):
        if book not in books:
            books[book] = book_verses(book, cache_dir, unknown)
        return books[book]

    sets = {}
    for set_id in SET_ORDER:
        mysteries = []
        for n, spec in enumerate(MYSTERIES[set_id], start=1):
            try:
                scripture = build_fragment(spec["fragment"], lookup, "Torres Amat (ed. 1836)", "es")
            except MissingVerse as missing:
                raise SourceError("verse text missing for %s %d (%s); add a 'cf.' paraphrase"
                                  % (set_id, n, missing)) from missing
            mysteries.append({
                "number": n,
                "title": titles[set_id][n - 1],
                "reference": spec["reference"],
                "scripture": scripture,
                "fruit": spec["fruit"],
                "meditation": spec["meditation"],
            })
        sets[set_id] = {"id": set_id, "title": SET_TITLES["es"][set_id], "mysteries": mysteries}

    data = {
        "sources": {
            "prayers": VATICAN_URL,
            "fatima": EWTN_FATIMA_URL,
            "mystery_titles": VATICAN_URL,
            "scripture": "https://es.wikisource.org/wiki/La_Sagrada_Biblia",
        },
        "prayers": {pid: prayers[pid] for pid in PRAYER_ORDER},
        "sets": {set_id: sets[set_id] for set_id in SET_ORDER},
    }
    header = (
        "-- Generated by tools/gen_content.py. Do not edit by hand.\n"
        "-- Prayers: Holy See, Compendio del Catecismo, \"Oraciones comunes\";\n"
        "-- Fatima prayer: EWTN; scripture: Torres Amat via Spanish Wikisource.\n"
        "-- Fruits and meditations are original text written for this plugin.\n"
    )
    if unknown:
        print("warning: unknown templates expanded by last parameter:", sorted(unknown), file=sys.stderr)
    return header, data


def translated_fragment(spec, scripture, lang, where):
    """The scripture of a mystery in `lang`, or None when its source lacks a
    verse. A dropped fragment is reported on stderr; the build still succeeds
    because the plugin shows the Spanish fragment instead.

    `scripture` is (lookup, translation, ...) as for build_translated.
    """
    lookup, translation = scripture[:2]
    try:
        return build_fragment(spec, lookup, translation, lang)
    except MissingVerse as missing:
        print("warning: %s %s: no text for %s, the plugin shows the Spanish fragment"
              % (lang, where, missing), file=sys.stderr)
        return None


def build_translated(lang, cache_dir, scripture):
    """Content of a language other than Spanish, as a data table.

    Prayers and mystery titles come from the Compendium page of the language,
    the Fatima prayer from FATIMA, fruits and meditations from TRANSLATIONS.
    `scripture` is (lookup, translation, sources url) for build_fragment; see
    translated_fragment for a mystery whose verses the source lacks.
    """
    code, anchor = COMPENDIUM[lang]
    url = VATICAN_PAGE % code
    page = fetch(url, cache_dir, "compendium_%s.html" % code).decode("iso-8859-1")
    prayers = compendium_prayers(vatican_bodies(page), lang, url + "#" + anchor)
    fatima_url, marker, title = FATIMA[lang]
    prayers["fatima"] = parse_fatima(fetch(fatima_url, cache_dir, "fatima_%s.html" % lang).decode("utf-8"),
                                     marker, title, fatima_url)
    titles = parse_titles(page, *TITLE_HEADINGS[lang])

    sets = {}
    for set_id in SET_ORDER:
        mysteries = []
        for n, spec in enumerate(MYSTERIES[set_id], start=1):
            fruit, meditation = TRANSLATIONS[lang][set_id][n - 1]
            mystery = {
                "number": n,
                "title": titles[set_id][n - 1],
                "reference": "; ".join(format_passage(*p, lang=lang)
                                       for p in parse_reference(spec["reference"])),
            }
            fragment = translated_fragment(spec["fragment"], scripture, lang, "%s %d" % (set_id, n))
            if fragment is not None:
                mystery["scripture"] = fragment
            mystery["fruit"] = fruit
            mystery["meditation"] = meditation
            mysteries.append(mystery)
        sets[set_id] = {"id": set_id, "title": SET_TITLES[lang][set_id], "mysteries": mysteries}

    return {
        "sources": {"prayers": url, "fatima": fatima_url, "mystery_titles": url,
                    "scripture": scripture[2]},
        "prayers": {pid: prayers[pid] for pid in PRAYER_ORDER},
        "sets": {set_id: sets[set_id] for set_id in SET_ORDER},
    }


def build_en(cache_dir):
    """English content: returns (header, data) for content/en.lua."""
    books = douay_rheims_verses(cache_dir)

    def lookup(book, chapter):
        return books[book], DOUAY_RHEIMS_PAGE

    data = build_translated("en", cache_dir, (lookup, "Douay-Rheims, Challoner revision",
                                              DOUAY_RHEIMS_PAGE))
    header = (
        "-- Generated by tools/gen_content.py. Do not edit by hand.\n"
        "-- Prayers and mystery titles: Holy See, Compendium of the Catechism, \"Common Prayers\";\n"
        "-- Fatima prayer: Shrine of Fatima; scripture: Douay-Rheims (Challoner revision)\n"
        "-- via Project Gutenberg.\n"
        "-- Fruits and meditations: translated from the Spanish ones written for this plugin.\n"
    )
    return header, data


def build_pt(cache_dir):
    """Portuguese content: returns (header, data) for content/pt.lua."""
    books = almeida_verses(cache_dir)

    def lookup(book, chapter):
        return books[book], ALMEIDA_PAGE

    data = build_translated("pt", cache_dir, (lookup, ALMEIDA_TRANSLATION, ALMEIDA_PAGE))
    header = (
        "-- Generated by tools/gen_content.py. Do not edit by hand.\n"
        "-- Prayers and mystery titles: Holy See, Compêndio do Catecismo, \"Orações comuns\";\n"
        "-- Fatima prayer: Shrine of Fatima; scripture: João Ferreira de Almeida, Edição Revista\n"
        "-- e Corrigida (Lisbon, 1911 reprint of the 1900 edition), via Project Gutenberg.\n"
        "-- Fruits and meditations: translated from the Spanish ones written for this plugin.\n"
    )
    return header, data


def build_it(cache_dir):
    """Italian content: returns (header, data) for content/it.lua."""
    def lookup(book, chapter):
        return martini_chapter(book, chapter, cache_dir)

    data = build_translated("it", cache_dir, (lookup, "Antonio Martini", "https://parolaviva.art/bibbia/"))
    header = (
        "-- Generated by tools/gen_content.py. Do not edit by hand.\n"
        "-- Prayers and mystery titles: Holy See, Compendio del Catechismo, \"Preghiere comuni\";\n"
        "-- Fatima prayer: Shrine of Fatima; scripture: Martini Bible via parolaviva.art.\n"
        "-- Fruits and meditations: translated from the Spanish ones written for this plugin.\n"
    )
    return header, data


def build_la(cache_dir):
    """Latin content: returns (header, data) for content/la.lua."""
    books = {}

    def lookup(book, chapter):
        if book not in books:
            books[book] = vulgate_book(book, cache_dir)
        return books[book]

    data = build_translated("la", cache_dir, (lookup, "Vulgata Clementina",
                                              "https://la.wikisource.org/wiki/Vulgata_Clementina"))
    header = (
        "-- Generated by tools/gen_content.py. Do not edit by hand.\n"
        "-- Prayers and mystery titles: Holy See, Compendium of the Catechism (English edition),\n"
        "-- Latin texts of \"Common Prayers\"; Fatima prayer: EWTN; scripture: Clementine Vulgate\n"
        "-- via Latin Wikisource.\n"
        "-- Fruits and meditations: translated from the Spanish ones written for this plugin.\n"
    )
    return header, data


# A builder takes the cache directory and returns the module header (Lua
# comments naming the sources) and the data table. The languages are those
# of the plugin (rosario.koplugin/i18n.lua), in the same order.
BUILDERS = {
    "es": build_es,
    "en": build_en,
    "pt": build_pt,
    "la": build_la,
    "it": build_it,
}


def main(argv):
    parser = argparse.ArgumentParser()
    parser.add_argument("--lang", default="es", choices=list(BUILDERS),
                        help="language of the content module (default: es)")
    parser.add_argument("--cache", help="directory for downloaded sources")
    parser.add_argument("--out", help="output path (default: rosario.koplugin/content/LANG.lua)")
    args = parser.parse_args(argv)
    out = args.out or os.path.join(
        os.path.dirname(os.path.abspath(__file__)), "..", "rosario.koplugin", "content", args.lang + ".lua")
    cache_dir = args.cache or tempfile.mkdtemp(prefix="rosario_sources_")
    os.makedirs(cache_dir, exist_ok=True)

    header, data = BUILDERS[args.lang](cache_dir)
    with open(out, "w", encoding="utf-8") as fh:
        fh.write(header + "return " + emit(data) + "\n")
    print("wrote", os.path.normpath(out))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
