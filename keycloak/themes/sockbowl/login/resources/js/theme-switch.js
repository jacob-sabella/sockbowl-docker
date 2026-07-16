/*
 * Sockbowl login theme switcher.
 *
 * The SPA passes the user's chosen theme through the sign-in redirect as
 * ?ui_theme=<name>. This runs from <head> (base keycloak emits `scripts` as
 * classic, non-deferred <script> tags), so it stamps the theme onto <html>
 * before the body paints — no flash of the default palette.
 *
 * The query param only rides on the first page of the flow; later pages
 * (wrong password, register, etc.) POST to login-actions URLs that drop it, so
 * we mirror the choice into a short-lived cookie and fall back to it.
 */
(function () {
  var ALLOWED = [
    'light', 'dark', 'nord', 'monokai',
    'catppuccin', 'dracula', 'solarized-dark', 'solarized-light'
  ];

  function fromQuery() {
    try {
      return new URLSearchParams(window.location.search).get('ui_theme');
    } catch (e) {
      return null;
    }
  }

  function fromCookie() {
    var m = document.cookie.match(/(?:^|;\s*)sb_login_theme=([^;]+)/);
    return m ? decodeURIComponent(m[1]) : null;
  }

  var theme = fromQuery() || fromCookie();
  if (theme && ALLOWED.indexOf(theme) !== -1) {
    document.documentElement.setAttribute('data-sb-theme', theme);
    // Persist for the rest of the auth flow (30 min is plenty for one sign-in).
    document.cookie = 'sb_login_theme=' + encodeURIComponent(theme) +
      '; path=/; max-age=1800; SameSite=Lax';
  }
})();
