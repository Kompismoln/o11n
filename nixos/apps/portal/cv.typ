#let cv = toml(sys.inputs.data)
#let lang = sys.inputs.lang
#let t = json(sys.inputs.strings).at(lang)
#let accent = if sys.inputs.accent.starts-with("#") { rgb(sys.inputs.accent) } else { luma(20) }
#let muted = luma(95)

#set document(title: cv.name, author: cv.name, date: none)
#set page(
  paper: "a4",
  margin: (x: 2.2cm, y: 2cm),
  footer: align(right, text(size: 8pt, fill: muted, link(sys.inputs.url, sys.inputs.url.split("://").last()))),
)
#set text(font: "Inter", size: 9.5pt, lang: lang, fill: luma(20))
#set par(leading: 0.62em, spacing: 0.9em)
#set list(marker: text(fill: accent)[•], indent: 0.2em, body-indent: 0.6em, spacing: 0.55em)

#show heading.where(level: 2): it => block(above: 2em, below: 0.9em, sticky: true)[
  #text(size: 8.5pt, weight: "bold", fill: accent, tracking: 0.08em, upper(it.body))
  #v(-0.6em)
  #line(length: 100%, stroke: 0.5pt + luma(215))
]

#let period(entry) = if "from" in entry {
  str(entry.from) + "–" + str(entry.at("to", default: t.cv_present))
}

#let pairs(rows) = grid(columns: (auto, 1fr), column-gutter: 1.2em, row-gutter: 0.7em, ..rows.flatten())

#let icon(name) = box(height: 0.85em, baseline: 0.12em, image(
  bytes(read(sys.inputs.icons + "/" + name + ".svg").replace("currentColor", muted.to-hex())),
  format: "svg",
  height: 100%,
))
#let row(name, body) = grid(columns: (auto, auto), column-gutter: 0.5em, icon(name), body)
#let links = cv.at("links", default: ()).map(it => {
  let name = if it.url.contains("github.com") { "github" } else if it.url.contains("linkedin.com") { "linkedin" } else {
    "link"
  }
  row(name, link(it.url, it.name))
})
#let contact = (
  (if "email" in cv { (row("mail", link("mailto:" + cv.email, cv.email)),) } else { () })
    + links
    + (if "business" in cv { (row("briefcase", cv.business),) } else { () })
)

#grid(
  columns: (1fr, auto),
  column-gutter: 1.5em,
  [
    #text(size: 22pt, weight: "bold", tracking: -0.02em, cv.name)
    #if "title" in cv {
      block(above: 0.6em, text(size: 12pt, weight: "medium", fill: accent, cv.title))
    }
    #let facts = ("location", "availability").filter(key => key in cv).map(key => cv.at(key))
    #if facts.len() > 0 {
      block(above: 0.6em, text(fill: muted, facts.join(" · ")))
    }
  ],
  if contact.len() > 0 {
    text(size: 8.5pt, fill: muted, stack(spacing: 0.55em, ..contact))
  },
)

#if "available" in cv {
  block(above: 1.2em, sticky: true, text(size: 8pt, fill: muted, t.cv_available))
  grid(
    columns: cv.available.len(),
    column-gutter: 2pt,
    row-gutter: 3pt,
    align: center + bottom,
    ..cv.available.map(entry => box(width: 1.1cm, height: 0.9cm, fill: accent.transparentize(88%), radius: (top: 2pt))[
      #place(bottom, rect(width: 100%, height: entry.percent * 1%, fill: accent, radius: (top: 2pt)))
    ]),
    ..cv.available.enumerate().map(((i, entry)) => text(size: 8pt, fill: muted, t.at("month_" + entry.month.slice(5)) + if i == cv.available.len() - 1 { " →" } else { "" })),
  )
}

#if "profile" in cv [
  == #t.cv_profile
  #for paragraph in cv.profile { par(paragraph) }
]

#if "skills" in cv [
  == #t.cv_skills
  #pairs(cv.skills.map(skill => (text(weight: "semibold", skill.group), skill.items.join(" · "))))
]

#if "experience" in cv [
  == #t.cv_experience
  #for entry in cv.experience {
    block(above: 1.4em, sticky: true, grid(
      columns: (1fr, auto),
      column-gutter: 1em,
      [#text(weight: "semibold", entry.role)#if "employer" in entry [ · #entry.employer]],
      text(fill: muted, period(entry)),
    ))
    if "summary" in entry { par(entry.summary) }
    if "points" in entry { list(..entry.points) }
  }
]

#if "education" in cv [
  == #t.cv_education
  #for entry in cv.education {
    block(above: 1em)[
      #text(weight: "semibold", entry.title)#if "from" in entry [, #period(entry)]
      #if "text" in entry [ \ #entry.text]
    ]
  }
]

#if "languages" in cv [
  == #t.cv_languages
  #pairs(cv.languages.map(language => (text(weight: "semibold", language.name), language.level)))
]
