#!/bin/sh

echo "Deploying myblog to github and coding.net..."

# generate static html, css file using hugo
hugo

# copy some static content to ./public to publish
cp -rf ./cp_to_public/* ./public/

git add -A

if [ $# -eq 1 ]; then
    git commit -m "$1"
else
    git commit
fi

# if no commit messager found, just exit
if [ $? -ne 0 ]; then
    exit 1
fi

# push to github
git push origin master
# now i use coding.net, so comment this line
git subtree push --prefix=public git@github.com:fatedier/just-my-blog.git gh-pages

# push to coding.net
git remote add coding git@git.coding.net:fatedier/just-my-blog.git 1> /dev/null 2>&1

git push coding master
git subtree push --prefix=public git@git.coding.net:fatedier/just-my-blog.git gh-pages
