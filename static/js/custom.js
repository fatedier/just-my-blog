// 去除 hugo 自动生成的导航的 h1 h2 的部分
var children = $("#TableOfContents").children().first().children().first().children().first().children().first().children().first();
console.log(children);
$("#TableOfContents").children().first().remove();
$("#TableOfContents").append(children);
