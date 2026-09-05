package com.fabricnavigator.security;

import java.io.IOException;
import java.net.URI;
import java.net.URLEncoder;
import java.util.Locale;
import javax.servlet.Filter;
import javax.servlet.FilterChain;
import javax.servlet.FilterConfig;
import javax.servlet.ServletException;
import javax.servlet.ServletRequest;
import javax.servlet.ServletResponse;
import javax.servlet.http.HttpServletRequest;
import javax.servlet.http.HttpServletResponse;
import javax.servlet.http.HttpSession;

/** Application authentication filter with an isolated bearer-token API path. */
public final class AuthFilter implements Filter {
    public void init(FilterConfig ignored) {}
    public void destroy() {}

    public void doFilter(ServletRequest servletRequest, ServletResponse servletResponse, FilterChain chain)
            throws IOException, ServletException {
        HttpServletRequest request = (HttpServletRequest) servletRequest;
        HttpServletResponse response = (HttpServletResponse) servletResponse;
        securityHeaders(response);
        String path = request.getRequestURI().substring(request.getContextPath().length());
        try {
            if (!isSecureRequest(request)) {
                response.setStatus(302);
                response.setHeader("Location", requestBase(request) + request.getRequestURI());
                return;
            }
            // API endpoints perform their own scoped bearer-token validation and
            // must never inherit an interactive browser session.
            if (path.startsWith("/api/v1/")) {
                chain.doFilter(request, response);
                return;
            }
            boolean hasUsers = EdmSecurity.hasUsers();
            if (!hasUsers) {
                if (isSetup(path) || isAsset(path)) { chain.doFilter(request, response); return; }
                response.sendRedirect(requestBase(request) + "/setup.jsp");
                return;
            }
            EdmSecurity.User user = EdmSecurity.validateAuthToken(EdmSecurity.authToken(request));
            if (isSetup(path)) {
                response.sendRedirect(requestBase(request) + (user == null ? "/login.jsp" : "/"));
                return;
            }
            if (isAsset(path) || isHealth(path)) { chain.doFilter(request, response); return; }
            if (isLogin(path)) {
                if (user != null) { response.sendRedirect(requestBase(request) + "/"); return; }
                chain.doFilter(request, response);
                return;
            }
            if (user == null) {
                String next = request.getRequestURI();
                if (request.getQueryString() != null && request.getQueryString().length() < 512) next += "?" + request.getQueryString();
                response.sendRedirect(requestBase(request) + "/login.jsp?next=" + URLEncoder.encode(next, "UTF-8"));
                return;
            }
            if (isUnsafe(request.getMethod()) && !validSameOrigin(request)) {
                response.sendError(403, "Cross-site request rejected");
                return;
            }
            if (path.startsWith("/admin") && !"ADMIN".equals(user.role)) { response.sendError(403); return; }
            HttpSession session = request.getSession(true);
            session.setMaxInactiveInterval(1800);
            session.setAttribute("edm.auth.user", user.username);
            session.setAttribute("edm.auth.role", user.role);
            request.setAttribute("edm.auth.user", user);
            chain.doFilter(request, response);
        } catch (Exception error) {
            throw new ServletException("Authentication service unavailable", error);
        }
    }

    static boolean isSecureRequest(HttpServletRequest request) {
        return request.isSecure() || "https".equalsIgnoreCase(forwardedValue(request.getHeader("X-Forwarded-Proto")));
    }
    static boolean validSameOrigin(HttpServletRequest request) {
        String origin=request.getHeader("Origin"),site=request.getHeader("Sec-Fetch-Site");
        if(origin!=null&&origin.trim().length()>0&&!"null".equalsIgnoreCase(origin.trim())){
            String normalized=normalizeOrigin(origin),external=externalOrigin(request);
            if(normalized.length()>0&&normalized.equals(external))return true;
            return "same-origin".equalsIgnoreCase(site);
        }
        return "same-origin".equalsIgnoreCase(site)||EdmSecurity.validCsrf(request);
    }
    static String externalOrigin(HttpServletRequest request) {
        String scheme=forwardedValue(request.getHeader("X-Forwarded-Proto"));if(scheme.length()==0)scheme=request.getScheme();
        String host=forwardedValue(request.getHeader("X-Forwarded-Host"));if(host.length()==0)host=request.getHeader("Host");
        if(host==null||host.trim().length()==0)host=request.getServerName()+(request.getServerPort()>0?":"+request.getServerPort():"");
        return normalizeOrigin(scheme+"://"+host.trim());
    }
    private static String requestBase(HttpServletRequest request){String origin=externalOrigin(request);return origin.length()>0?origin:publicBase();}
    private static String forwardedValue(String value){if(value==null)return"";int comma=value.indexOf(',');return(comma<0?value:value.substring(0,comma)).trim();}
    private static String normalizeOrigin(String value){
        try{URI uri=new URI(value.trim());String scheme=uri.getScheme(),host=uri.getHost();if(scheme==null||host==null||uri.getUserInfo()!=null||uri.getRawQuery()!=null||uri.getRawFragment()!=null)return"";scheme=scheme.toLowerCase(Locale.ENGLISH);if(!"https".equals(scheme)&&!"http".equals(scheme))return"";String path=uri.getRawPath();if(path!=null&&path.length()>0&&!"/".equals(path))return"";int port=uri.getPort();boolean standard=port<0||("https".equals(scheme)&&port==443)||("http".equals(scheme)&&port==80);host=host.toLowerCase(Locale.ENGLISH);if(host.indexOf(':')>=0)host="["+host+"]";return scheme+"://"+host+(standard?"":":"+port);}catch(Exception ignored){return"";}
    }
    private static boolean isUnsafe(String method){return!"GET".equals(method)&&!"HEAD".equals(method)&&!"OPTIONS".equals(method);}
    private static boolean isAsset(String path){return path.startsWith("/assets/")||"/favicon.ico".equals(path);}
    private static boolean isSetup(String path){return"/setup.jsp".equals(path)||"/setup".equals(path);}
    private static boolean isLogin(String path){return"/login.jsp".equals(path)||"/login".equals(path);}
    private static boolean isHealth(String path){return"/health.jsp".equals(path);}
    static String publicBase(){String value=System.getProperty("edm.public.baseUrl","https://192.168.1.37");return value.endsWith("/")?value.substring(0,value.length()-1):value;}
    private static void securityHeaders(HttpServletResponse response){
        response.setHeader("Content-Security-Policy","default-src 'self'; script-src 'self' 'unsafe-inline'; style-src 'self' 'unsafe-inline'; connect-src 'self' ws: wss:; img-src 'self' data:; font-src 'self'; object-src 'none'; base-uri 'self'; frame-ancestors 'self'; form-action 'self'");
        response.setHeader("X-Content-Type-Options","nosniff");response.setHeader("X-Frame-Options","SAMEORIGIN");response.setHeader("Referrer-Policy","no-referrer");response.setHeader("Permissions-Policy","camera=(), microphone=(), geolocation=(), payment=(), usb=()");response.setHeader("Cache-Control","no-store");
    }
}
