# Verto Image Library

Drop image files (`.jpg`, `.jpeg`, `.png`, `.webp`, `.svg`) into this folder.
They are picked up automatically by the **Add media → Verto Library** picker
inside the survey editor (`app/views/surveys/show.html.erb`).

Recommended dimensions: tall portrait, ~9:16 ratio (the left card panel is
425 × 680 px). Filenames become the on-hover label.

The picker reads the directory at request time via
`SurveyHelper#verto_library_images`, so no manifest or rebuild is required —
just commit the file and refresh.
