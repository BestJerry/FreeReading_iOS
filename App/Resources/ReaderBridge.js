(function () {
    "use strict";
    if (window.FreeReading) return;
    var paged = true, lastHighlight = null, scrollTimer = null, touch = null, selectionTimer = null, navigationRevision = 0;
    var style = document.createElement("style");
    style.id = "fr-reader-style";
    document.head.appendChild(style);
    var layer = document.createElement("div");
    layer.id = "fr-highlight-layer";
    layer.setAttribute("aria-hidden", "true");
    layer.style.cssText = "position:absolute;left:0;top:0;width:0;height:0;pointer-events:none;z-index:2147483640;";
    document.documentElement.appendChild(layer);

    function post(type, value) {
        try { window.webkit.messageHandlers.freeReading.postMessage({type: type, value: value || {}}); } catch (_) {}
    }
    function sections() { return Array.from(document.querySelectorAll("[data-fr-section]")); }
    function sectionAt(node) {
        var element = node && (node.nodeType === Node.ELEMENT_NODE ? node : node.parentElement);
        return element && element.closest("[data-fr-section]");
    }
    function section(id) { return document.querySelector('[data-fr-section="' + Number(id) + '"]'); }
    function point(element, offset) {
        var walker = document.createTreeWalker(element, NodeFilter.SHOW_TEXT), node, left = Math.max(0, offset);
        while ((node = walker.nextNode())) {
            if (left <= node.textContent.length) return [node, left];
            left -= node.textContent.length;
        }
        return [element, element.childNodes.length];
    }
    function textRange(element, start, end) {
        var length = element.textContent.length;
        if (start < 0 || end < start || end > length) return null;
        var a = point(element, start), b = point(element, end), range = document.createRange();
        range.setStart(a[0], a[1]); range.setEnd(b[0], b[1]);
        return range;
    }
    function visible(rect) {
        return rect.width > 0 && rect.height > 0 && rect.right > 1 && rect.left < innerWidth - 1 &&
            rect.bottom > 1 && rect.top < innerHeight - 1;
    }
    function progress() {
        var scroller = document.scrollingElement;
        var total = paged ? scroller.scrollWidth - innerWidth : scroller.scrollHeight - innerHeight;
        var position = paged ? scrollX : scrollY;
        return total > 0 ? Math.min(1, Math.max(0, position / total)) : 0;
    }
    // 使用 DOM 中的原始 UTF-16 字符范围，不把浏览器页进度换算成正文比例。
    function anchor() {
        var found = sections().find(function (element) {
            var range = textRange(element, 0, element.textContent.length);
            return range && Array.from(range.getClientRects()).some(visible);
        });
        if (!found) return {sectionID: null, offset: 0, progress: progress()};
        var low = 0, high = Math.max(0, found.textContent.length - 1);
        while (low < high) {
            var middle = Math.floor((low + high) / 2);
            var range = textRange(found, middle, middle + 1);
            var rect = range && range.getBoundingClientRect();
            var before = rect && (paged ? rect.right <= 1 : rect.bottom <= 1);
            if (before) low = middle + 1; else high = middle;
        }
        return {sectionID: Number(found.getAttribute("data-fr-section")), offset: low, progress: progress()};
    }
    function selectionAnchor() {
        var selected = getSelection();
        if (!selected || selected.isCollapsed || !selected.rangeCount || !selected.toString().trim()) return null;
        var range = selected.getRangeAt(0), element = sectionAt(range.startContainer);
        if (!element) {
            element = sections().find(function (candidate) {
                try { return range.intersectsNode(candidate); } catch (_) { return false; }
            });
            if (!element) return null;
            return {sectionID: Number(element.getAttribute("data-fr-section")), offset: 0, progress: progress()};
        }
        var before = document.createRange();
        before.selectNodeContents(element);
        before.setEnd(range.startContainer, range.startOffset);
        return {sectionID: Number(element.getAttribute("data-fr-section")), offset: before.toString().length, progress: progress()};
    }
    function contents(entries) {
        var a = anchor(), current = a.sectionID === null ? null : section(a.sectionID);
        var cursor = current && textRange(current, a.offset, a.offset);
        var result = null, boundary = null, depth = -1;
        entries.forEach(function (entry) {
            if (!entry.fragment) {
                if (!boundary && entry.depth >= depth) { result = entry.id; depth = entry.depth; }
                return;
            }
            if (!cursor) return;
            var element = document.getElementById(entry.fragment);
            if (!element) return;
            var range = document.createRange();
            range.setStart(element, 0); range.collapse(true);
            if (range.compareBoundaryPoints(Range.START_TO_START, cursor) > 0) return;
            var order = boundary ? range.compareBoundaryPoints(Range.START_TO_START, boundary) : 1;
            if (order > 0 || (order === 0 && entry.depth >= depth)) {
                result = entry.id; boundary = range; depth = entry.depth;
            }
        });
        return result;
    }
    function locate(rect) {
        if (!rect) return;
        if (paged) {
            var page = Math.floor((rect.left + scrollX + 0.5) / Math.max(1, innerWidth));
            scrollTo({left: page * innerWidth, top: 0, behavior: "instant"});
        } else {
            scrollTo({left: 0, top: Math.max(0, rect.top + scrollY - 26), behavior: "instant"});
        }
    }
    function navigate(target) {
        navigationRevision += 1;
        if (target.kind === "progress") {
            var scroller = document.scrollingElement;
            if (paged) {
                var last = Math.max(0, Math.ceil(scroller.scrollWidth / innerWidth) - 1);
                scrollTo(Math.round(last * target.value) * innerWidth, 0);
            } else scrollTo(0, Math.max(0, scroller.scrollHeight - innerHeight) * target.value);
        } else if (target.kind === "fragment") {
            var element = document.getElementById(target.value);
            if (element) locate(element.getBoundingClientRect());
        } else if (target.kind === "section") {
            var block = section(target.sectionID);
            if (block) {
                var offset = Math.min(Math.max(0, target.offset || 0), block.textContent.length);
                var range = textRange(block, offset, Math.min(block.textContent.length, offset + 1));
                locate(range && range.getBoundingClientRect());
            }
        }
        setTimeout(function () { post("anchor", anchor()); }, 40);
    }
    function drawHighlight(target, move) {
        layer.replaceChildren();
        if (!target) return;
        var element = section(target.sectionID);
        if (!element) return;
        var range = textRange(element, target.start, target.end);
        if (!range) return;
        if (move) { navigationRevision += 1; locate(range.getClientRects()[0] || range.getBoundingClientRect()); }
        Array.from(range.getClientRects()).forEach(function (rect) {
            if (rect.width <= 0 || rect.height <= 0) return;
            var mark = document.createElement("div");
            mark.style.cssText = "position:absolute;border-radius:3px;background:rgba(188,169,86,.30);pointer-events:none;";
            mark.style.left = (rect.left + scrollX) + "px"; mark.style.top = (rect.top + scrollY) + "px";
            mark.style.width = rect.width + "px"; mark.style.height = rect.height + "px";
            layer.appendChild(mark);
        });
    }
    function configure(options) {
        var previous = anchor();
        paged = !options.scroll;
        document.documentElement.classList.toggle("fr-paged", paged);
        document.documentElement.classList.toggle("fr-scroll", !paged);
        var paper = options.paper || "#f7f5ef", ink = options.ink || "#283c32";
        style.textContent =
            "html{background:" + paper + "!important;color:" + ink + "!important;overflow-anchor:none;}" +
            "body{background:" + paper + "!important;color:" + ink + "!important;font-size:" + options.fontSize + "px!important;line-height:1.85!important;-webkit-text-size-adjust:100%!important;word-wrap:break-word;}" +
            "html.fr-paged{height:100%;overflow-x:auto;overflow-y:hidden;}html.fr-paged body{box-sizing:content-box!important;margin:0!important;padding:24px 28px!important;width:calc(100vw - 56px)!important;height:calc(100vh - 48px)!important;column-width:calc(100vw - 56px)!important;column-gap:56px!important;column-fill:auto!important;overflow:visible!important;}" +
            "html.fr-scroll{overflow-x:hidden;overflow-y:auto;}html.fr-scroll body{box-sizing:border-box!important;width:100%!important;margin:0!important;padding:24px 28px!important;}" +
            "img,svg,video{max-width:100%!important;height:auto!important;}html.fr-paged img{max-height:85vh!important;object-fit:contain;}" +
            "p,h1,h2,h3,h4,h5,h6,li,blockquote{color:inherit!important;}a{color:inherit;}#fr-highlight-layer,#fr-highlight-layer *{pointer-events:none!important;}";
        var revision = navigationRevision;
        requestAnimationFrame(function () {
            if (revision === navigationRevision && previous.sectionID !== null) navigate({kind: "section", sectionID: previous.sectionID, offset: previous.offset});
            drawHighlight(lastHighlight, false);
        });
    }
    window.FreeReading = {
        anchor: anchor, selectionAnchor: selectionAnchor, contents: contents, configure: configure, navigate: navigate,
        highlight: function (target) { lastHighlight = target; drawHighlight(target, !!(target && target.navigate)); },
        clearSelection: function () { var selected = getSelection(); if (selected) selected.removeAllRanges(); }
    };
    document.addEventListener("click", function (event) {
        var link = event.target.closest && event.target.closest("a[href]");
        if (link) {
            event.preventDefault(); event.stopPropagation();
            post("link", {href: link.getAttribute("href")}); return;
        }
        if (getSelection() && !getSelection().isCollapsed) return;
        if (touch && (touch.moved || Date.now() - touch.time > 550)) return;
        event.preventDefault(); event.stopPropagation(); post("tap");
    }, true);
    document.addEventListener("touchstart", function (event) {
        var p = event.touches[0];
        touch = {x: p.clientX, y: p.clientY, scroll: scrollX, time: Date.now(), moved: false};
    }, {passive: true});
    document.addEventListener("touchmove", function (event) {
        if (!touch) return;
        var p = event.touches[0], dx = p.clientX - touch.x, dy = p.clientY - touch.y;
        if (!touch.moved && (Math.abs(dx) > 10 || (!paged && Math.abs(dy) > 10))) {
            touch.moved = true; post("manual", {reason: "swipe"});
        }
    }, {passive: true});
    document.addEventListener("touchend", function (event) {
        if (!touch || !event.changedTouches.length) return;
        var p = event.changedTouches[0], dx = p.clientX - touch.x, dy = p.clientY - touch.y;
        if (Math.abs(dx) > 65 && Math.abs(dx) > Math.abs(dy) * 1.4) {
            var maximum = Math.max(0, document.scrollingElement.scrollWidth - innerWidth);
            if (!paged || (dx < 0 && touch.scroll >= maximum - 3) || (dx > 0 && touch.scroll <= 3)) {
                post("chapter", {delta: dx < 0 ? 1 : -1});
            }
        }
    }, {passive: true});
    document.addEventListener("selectionchange", function () {
        clearTimeout(selectionTimer);
        selectionTimer = setTimeout(function () {
            var value = selectionAnchor();
            if (value) post("manual", {reason: "selection"});
            post("selection", {active: !!value});
        }, 80);
    });
    addEventListener("scroll", function () {
        clearTimeout(scrollTimer);
        scrollTimer = setTimeout(function () { post("anchor", anchor()); }, 120);
    }, {passive: true});
    addEventListener("resize", function () { drawHighlight(lastHighlight, false); });
    document.fonts.ready.then(function () { drawHighlight(lastHighlight, false); });
    post("ready", anchor());
})();
