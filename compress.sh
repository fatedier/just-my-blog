#!/bin/sh

oocss='./static/onlyone/onlyone.css'
oojs='./static/onlyone/onlyone.js'

# clear generate file
> ${oocss}
> ${oojs}

# compress css
cat ./static/bs/css/bootstrap.min.css >> ${oocss}
cat ./static/css/hightlight/tomorrow-night.min.css >> ${oocss}
cat ./static/bs/css/font-awesome.min.css >> ${oocss}
cat ./static/css/styles.css >> ${oocss}
cat ./static/css/custom.css >> ${oocss}

# compress js
cat ./static/js/jquery-2.2.1.min.js >> ${oojs}
cat ./static/js/bootstrap.min.js >> ${oojs}
cat ./static/js/highlight.min.js >> ${oojs}
# cat ./static/js/custom.js >> ${oojs}
