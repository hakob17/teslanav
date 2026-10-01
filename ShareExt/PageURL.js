// Safari runs this when sharing to HotspotNav: it hands over the page's real address. Safari
// itself shares the page's canonical URL, which for map sites drops the coordinates
// (yandex.com/maps/?text=40.35,44.59 is shared as yandex.com/maps/).
var PageURL = function () {};
PageURL.prototype = {
  run: function (args) { args.completionFunction({ url: document.URL, title: document.title }); },
  finalize: function () {}
};
var ExtensionPreprocessingJS = new PageURL();
