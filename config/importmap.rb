# Pin npm packages by running ./bin/importmap

pin "application"
pin "sw_register"
pin "@hotwired/turbo-rails", to: "turbo.min.js"
pin "@hotwired/stimulus", to: "stimulus.min.js"
pin "@hotwired/stimulus-loading", to: "stimulus-loading.js"
pin "lottie-web", to: "lottie-web.js"
# Controllers + lib modules are lazy-loaded via stimulus-loading or
# explicit imports — emitting modulepreload links for all of them on
# every page defeats the lazy loader and forces a cold cache to fetch
# 30+ modules upfront, which dominated first-paint on Render starter.
pin_all_from "app/javascript/controllers", under: "controllers", preload: false
pin_all_from "app/javascript/lib", under: "lib", preload: false
