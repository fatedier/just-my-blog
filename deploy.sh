#!/bin/sh

echo "Deploying myblog to github..."

hugo

cp -rf ./cp_to_public/* ./public/

git add -A

if [ $# -eq 1 ]; then
    git commit -m "$1"
else
    git commit
fi

git push origin master

git subtree push --prefix=public git@github.com:fatedier/just-my-blog.git gh-pages
