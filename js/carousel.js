/**
 * carousel.js – Shared media carousel for multi-photo posts and video.
 *
 * Provides factory methods to create swipeable carousels with dot
 * indicators, plus helpers to detect post media types.
 */

// eslint-disable-next-line no-unused-vars
const CarouselFactory = (() => {
  "use strict";

  const WEB_DIR = "photos/web/";

  /**
   * Get the media array from a photo object, with legacy fallback.
   * @param {Object} photo - A photo entry from photos.json
   * @returns {Array} Array of { type, web, thumbnail, poster?, duration? }
   */
  function getMedia(photo) {
    if (photo.media && photo.media.length > 0) return photo.media;
    return [{ type: "image", web: photo.web, thumbnail: photo.thumbnail }];
  }

  /** True if the post has more than one media item */
  function isMulti(photo) {
    return getMedia(photo).length > 1;
  }

  /** True if the first (or only) media item is a video */
  function isVideo(photo) {
    const m = getMedia(photo);
    return m[0] && m[0].type === "video";
  }

  /**
   * Create a carousel/media DOM element for the given media items.
   *
   * For a single image it returns a plain <img>.
   * For a single video it returns a <video>.
   * For multiple items it returns a swipeable carousel container.
   *
   * @param {Array}  mediaItems - media array
   * @param {Object} options
   *   baseUrl   {string}  – remote base URL (empty for local)
   *   alt       {string}  – alt text for images
   *   lazy      {boolean} – use data-src for lazy loading
   *   className {string}  – extra CSS class on wrapper
   *   imgClass  {string}  – CSS class for <img> / <video> elements
   * @returns {HTMLElement}
   */
  function create(mediaItems, options = {}) {
    const baseUrl = options.baseUrl || "";
    const webDir = baseUrl ? baseUrl + "photos/web/" : WEB_DIR;
    const imgClass = options.imgClass || "";

    // ---- Single image ----
    if (mediaItems.length === 1 && mediaItems[0].type !== "video") {
      const img = document.createElement("img");
      const src = webDir + mediaItems[0].web;
      if (options.lazy) {
        img.setAttribute("data-src", src);
        img.className = "lazy" + (imgClass ? " " + imgClass : "");
      } else {
        img.src = src;
        if (imgClass) img.className = imgClass;
      }
      img.alt = options.alt || "";
      if (baseUrl) img.setAttribute("crossorigin", "anonymous");
      return img;
    }

    // ---- Single video ----
    if (mediaItems.length === 1 && mediaItems[0].type === "video") {
      const video = document.createElement("video");
      video.src = webDir + mediaItems[0].web;
      if (mediaItems[0].poster) video.poster = webDir + mediaItems[0].poster;
      video.controls = true;
      video.playsInline = true;
      video.preload = "metadata";
      if (imgClass) video.className = imgClass;
      if (baseUrl) video.setAttribute("crossorigin", "anonymous");
      return video;
    }

    // ---- Multi-item carousel ----
    const container = document.createElement("div");
    container.className = "media-carousel" + (options.className ? " " + options.className : "");

    const track = document.createElement("div");
    track.className = "carousel-track";

    mediaItems.forEach((item) => {
      const slide = document.createElement("div");
      slide.className = "carousel-slide";

      if (item.type === "video") {
        const video = document.createElement("video");
        video.src = webDir + item.web;
        if (item.poster) video.poster = webDir + item.poster;
        video.controls = true;
        video.playsInline = true;
        video.preload = "metadata";
        if (baseUrl) video.setAttribute("crossorigin", "anonymous");
        slide.appendChild(video);
      } else {
        const img = document.createElement("img");
        const src = webDir + item.web;
        if (options.lazy) {
          img.setAttribute("data-src", src);
          img.className = "lazy";
        } else {
          img.src = src;
        }
        img.alt = options.alt || "";
        if (baseUrl) img.setAttribute("crossorigin", "anonymous");
        slide.appendChild(img);
      }

      track.appendChild(slide);
    });

    container.appendChild(track);

    // Dot indicators
    if (mediaItems.length > 1) {
      const dots = document.createElement("div");
      dots.className = "carousel-dots";
      mediaItems.forEach((_, i) => {
        const dot = document.createElement("button");
        dot.className = "carousel-dot" + (i === 0 ? " active" : "");
        dot.setAttribute("aria-label", "Slide " + (i + 1));
        dots.appendChild(dot);
      });
      container.appendChild(dots);
    }

    // Prev / Next arrow buttons
    if (mediaItems.length > 1) {
      const prevBtn = document.createElement("button");
      prevBtn.className = "carousel-arrow carousel-arrow-prev";
      prevBtn.setAttribute("aria-label", "Previous");
      prevBtn.innerHTML = '<i class="bi bi-chevron-left"></i>';

      const nextBtn = document.createElement("button");
      nextBtn.className = "carousel-arrow carousel-arrow-next";
      nextBtn.setAttribute("aria-label", "Next");
      nextBtn.innerHTML = '<i class="bi bi-chevron-right"></i>';

      container.appendChild(prevBtn);
      container.appendChild(nextBtn);

      function updateArrows() {
        prevBtn.classList.toggle("hidden", currentSlide === 0);
        nextBtn.classList.toggle("hidden", currentSlide === mediaItems.length - 1);
      }

      // Store reference so goTo can update
      container._updateArrows = updateArrows;
    }

    // ---- Carousel state ----
    let currentSlide = 0;

    // Now that currentSlide is defined, run initial arrow update
    if (container._updateArrows) container._updateArrows();

    function goTo(idx) {
      if (idx < 0 || idx >= mediaItems.length) return;
      currentSlide = idx;
      track.style.transform = "translateX(-" + (idx * 100) + "%)";
      container.querySelectorAll(".carousel-dot").forEach((d, i) => {
        d.classList.toggle("active", i === idx);
      });
      // Pause videos not on current slide
      container.querySelectorAll("video").forEach((v, vi) => {
        if (vi !== idx) v.pause();
      });
      // Update arrow visibility
      if (container._updateArrows) container._updateArrows();
    }

    // Expose API on the DOM element
    container._goTo = goTo;
    container._currentSlide = () => currentSlide;
    container._slideCount = () => mediaItems.length;

    // ---- Touch swipe ----
    let touchStartX = 0;
    let touchStartY = 0;
    let touchDeltaX = 0;
    let swiping = false;

    container.addEventListener("touchstart", (e) => {
      // Stop propagation so parent post-level swipe handlers don't fire
      e.stopPropagation();
      touchStartX = e.changedTouches[0].screenX;
      touchStartY = e.changedTouches[0].screenY;
      touchDeltaX = 0;
      swiping = false;
    }, { passive: true });

    container.addEventListener("touchmove", (e) => {
      const dx = e.changedTouches[0].screenX - touchStartX;
      const dy = e.changedTouches[0].screenY - touchStartY;
      if (!swiping && Math.abs(dx) > 10 && Math.abs(dx) > Math.abs(dy)) {
        swiping = true;
      }
      if (swiping) {
        e.stopPropagation();
        e.preventDefault(); // prevent page scroll during carousel swipe
        touchDeltaX = dx;
        const offset = -(currentSlide * 100) + (dx / container.offsetWidth) * 100;
        track.style.transition = "none";
        track.style.transform = "translateX(" + offset + "%)";
      }
    }, { passive: false });

    container.addEventListener("touchend", (e) => {
      if (!swiping) return;
      e.stopPropagation();
      track.style.transition = "transform 0.3s ease";
      if (Math.abs(touchDeltaX) > 50) {
        if (touchDeltaX < 0 && currentSlide < mediaItems.length - 1) {
          goTo(currentSlide + 1);
        } else if (touchDeltaX > 0 && currentSlide > 0) {
          goTo(currentSlide - 1);
        } else {
          goTo(currentSlide);
        }
      } else {
        goTo(currentSlide);
      }
      setTimeout(() => { track.style.transition = ""; }, 300);
      swiping = false;
    }, { passive: true });

    // Dot click + arrow click
    container.addEventListener("click", (e) => {
      const dot = e.target.closest(".carousel-dot");
      if (dot) {
        const idx = Array.from(dot.parentElement.children).indexOf(dot);
        track.style.transition = "transform 0.3s ease";
        goTo(idx);
        setTimeout(() => { track.style.transition = ""; }, 300);
        return;
      }
      const arrow = e.target.closest(".carousel-arrow");
      if (arrow) {
        e.stopPropagation(); // don't open lightbox / post page
        track.style.transition = "transform 0.3s ease";
        if (arrow.classList.contains("carousel-arrow-prev")) {
          goTo(currentSlide - 1);
        } else {
          goTo(currentSlide + 1);
        }
        setTimeout(() => { track.style.transition = ""; }, 300);
      }
    });

    return container;
  }

  return { create, getMedia, isMulti, isVideo };
})();
