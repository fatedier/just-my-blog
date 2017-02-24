// 去除 hugo 自动生成的导航的 h1 h2 的部分
// 这部分放到页面最后做，不然需要等 js 文件加载完成才能生效，网速慢的时候展示效果不好
/*
var children = $("#TableOfContents").children().first().children().first().children().first().children().first().children().first();
$("#TableOfContents").children().first().remove();
$("#TableOfContents").append(children);

var real = $("li#li-rels:lt(8)");
$("ul.post-rels").children().remove();
$("ul.post-rels").append(real);
if ($("ul.post-rels").children().length == 0) {
        $("#real-rels").remove();
}
*/
