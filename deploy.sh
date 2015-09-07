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

# push to github
git push origin master
# git subtree push --prefix=public git@github.com:fatedier/just-my-blog.git gh-pages

# push to gitcafe
git remote add gitcafe git@gitcafe.com:fatedier/just-my-blog.git 1> /dev/null 2>&1

git push gitcafe master
git subtree push --prefix=public git@gitcafe.com:fatedier/just-my-blog.git gh-pages
