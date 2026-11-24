(function () {
    "use strict";
    if (window.FreeReading) return;
    var paged = true, rtl = false, lastHighlight = null, scrollTimer = null, touch = null, selectionTimer = null, navigationRevision = 0;
    var highlightAtSwipe = null;
    // EPUB 常未声明移动端视口；否则 iOS 使用约 980px 的布局宽度，20px 正文会整体缩小。
    // XHTML 必须使用 HTML 命名空间创建 meta，且不限制用户放大手势。
    function ensureViewport() {
        var namespace = "http://www.w3.org/1999/xhtml";
        var head = document.head || document.documentElement.querySelector("head");
        if (!head) {
            head = document.createElementNS(namespace, "head");
            document.documentElement.insertBefore(head, document.documentElement.firstChild);
        }
        var existing = Array.from(head.querySelectorAll("meta[name]")).filter(function (meta) {
            return meta.getAttribute("name").trim().toLowerCase() === "viewport";
        });
        var viewport = existing.find(function (meta) { return meta.namespaceURI === namespace; });
        if (!viewport) viewport = document.createElementNS(namespace, "meta");
        existing.forEach(function (meta) { if (meta !== viewport) meta.remove(); });
        if (viewport.getAttribute("name") !== "viewport") viewport.setAttribute("name", "viewport");
        var content = "width=device-width, initial-scale=1";
        if (viewport.getAttribute("content") !== content) viewport.setAttribute("content", content);
        if (!viewport.parentNode) head.appendChild(viewport);
    }
    ensureViewport();
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
    // WebKit 的 RTL 横向滚动坐标为负数；所有页码与进度统一转换为从章首开始的正坐标。
    function maximumPosition() {
        var scroller = document.scrollingElement;
        return Math.max(0, paged ? scroller.scrollWidth - innerWidth : scroller.scrollHeight - innerHeight);
    }
    function readingPosition() { return Math.min(maximumPosition(), Math.max(0, paged ? (rtl ? -scrollX : scrollX) : scrollY)); }
    function scrollToPosition(position) {
        var value = Math.min(maximumPosition(), Math.max(0, position));
        if (paged) scrollTo({left: rtl ? -value : value, top: 0, behavior: "instant"});
        else scrollTo({left: 0, top: value, behavior: "instant"});
    }
    function progress() {
        var total = maximumPosition();
        return total > 0 ? readingPosition() / total : 0;
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
            var before = rect && (paged ? (rtl ? rect.left >= innerWidth - 1 : rect.right <= 1) : rect.bottom <= 1);
            if (before) low = middle + 1; else high = middle;
        }
        return {sectionID: Number(found.getAttribute("data-fr-section")), offset: low, progress: progress()};
    }
    function hasSelection() {
        var selected = getSelection();
        return selected && !selected.isCollapsed;
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
            var coordinate = rtl ? innerWidth - rect.right - scrollX : rect.left + scrollX;
            var page = Math.floor((coordinate + 0.5) / Math.max(1, innerWidth));
            scrollToPosition(page * innerWidth);
        } else {
            scrollToPosition(rect.top + scrollY - 26);
        }
    }
    function navigate(target) {
        navigationRevision += 1;
        if (target.kind === "progress") {
            if (paged) {
                var last = Math.max(0, Math.round(maximumPosition() / Math.max(1, innerWidth)));
                scrollToPosition(Math.round(last * Math.min(1, Math.max(0, target.value))) * innerWidth);
            } else scrollToPosition(maximumPosition() * Math.min(1, Math.max(0, target.value)));
        } else if (target.kind === "fragment") {
            var element = document.getElementById(target.value);
            if (element) {
                var fragmentRange = document.createRange();
                fragmentRange.selectNodeContents(element);
                locate(Array.from(fragmentRange.getClientRects()).find(function (rect) { return rect.width > 0 && rect.height > 0; }) || element.getBoundingClientRect());
            }
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
    function firstTextRect(range) {
        return Array.from(range.getClientRects()).find(function (rect) {
            return rect.width > 0 && rect.height > 0;
        });
    }
    function drawHighlight(target, move) {
        layer.replaceChildren();
        if (!target) return;
        var element = section(target.sectionID);
        if (!element) return;
        var range = textRange(element, target.start, target.end);
        if (!range) return;
        if (move) { navigationRevision += 1; locate(firstTextRect(range) || range.getBoundingClientRect()); }
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
        ensureViewport();
        paged = !options.scroll;
        rtl = options.direction === "rtl";
        document.documentElement.setAttribute("dir", rtl ? "rtl" : "ltr");
        document.documentElement.classList.toggle("fr-paged", paged);
        document.documentElement.classList.toggle("fr-scroll", !paged);
        var paper = options.paper || "#f7f5ef", ink = options.ink || "#283c32";
        style.textContent =
            "html{background:" + paper + "!important;color:" + ink + "!important;overflow-anchor:none;direction:" + (rtl ? "rtl" : "ltr") + "!important;}" +
            "body{background:" + paper + "!important;color:" + ink + "!important;direction:" + (rtl ? "rtl" : "ltr") + "!important;font-family:ui-serif,serif!important;font-size:" + options.fontSize + "px!important;line-height:1.8!important;-webkit-text-size-adjust:100%!important;word-wrap:break-word;}" +
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
        highlight: function (target) {
            // 手势消息还在去往 Swift 时，也拦住已进入 WebKit 的本句滚动请求。
            var sameAsSwipe = target && highlightAtSwipe &&
                target.sectionID === highlightAtSwipe.sectionID &&
                target.start === highlightAtSwipe.start && target.end === highlightAtSwipe.end;
            if (!(sameAsSwipe && target.navigate)) highlightAtSwipe = null;
            lastHighlight = target;
            drawHighlight(target, !!(target && target.navigate) && !sameAsSwipe && !hasSelection());
        },
        clearSelection: function () { var selected = getSelection(); if (selected) selected.removeAllRanges(); }
    };
    document.addEventListener("click", function (event) {
        var link = event.target.closest && event.target.closest("a[href]");
        if (link) {
            event.preventDefault(); event.stopPropagation();
            post("link", {href: link.getAttribute("href")}); return;
        }
        if (hasSelection()) return;
        if (touch && (touch.moved || Date.now() - touch.time > 550)) return;
        event.preventDefault(); event.stopPropagation(); post("tap");
    }, true);
    document.addEventListener("touchstart", function (event) {
        var p = event.touches[0];
        touch = {x: p.clientX, y: p.clientY, scroll: readingPosition(), time: Date.now(), moved: false};
    }, {passive: true});
    document.addEventListener("touchmove", function (event) {
        if (!touch) return;
        var p = event.touches[0], dx = p.clientX - touch.x, dy = p.clientY - touch.y;
        if (!touch.moved && (Math.abs(dx) > 10 || (!paged && Math.abs(dy) > 10))) {
            touch.moved = true;
            if (lastHighlight && lastHighlight.navigate) {
                highlightAtSwipe = lastHighlight;
                touch.shownSentence = lastHighlight.sentenceIndex;
            }
            post("manual", {shownSentence: touch.shownSentence});
        }
    }, {passive: true});
    document.addEventListener("touchend", function (event) {
        if (!touch || !event.changedTouches.length) return;
        var p = event.changedTouches[0], dx = p.clientX - touch.x, dy = p.clientY - touch.y;
        if (Math.abs(dx) > 65 && Math.abs(dx) > Math.abs(dy) * 1.4) {
            var delta = (dx < 0 ? 1 : -1) * (rtl ? -1 : 1);
            if (!paged || (delta > 0 && touch.scroll >= maximumPosition() - 3) || (delta < 0 && touch.scroll <= 3)) {
                post("chapter", {delta: delta, shownSentence: touch.shownSentence});
            }
        }
    }, {passive: true});
    document.addEventListener("selectionchange", function () {
        clearTimeout(selectionTimer);
        selectionTimer = setTimeout(function () {
            var value = selectionAnchor();
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
