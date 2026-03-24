FROM nginx:alpine

# nginx config (HTTP only - TLS terminated by ingress controller)
COPY nginx-k8s.conf /etc/nginx/nginx.conf

# Copy all resources to the correct path under the web root
COPY resources/ /usr/share/nginx/html/resources/

EXPOSE 80

CMD ["nginx", "-g", "daemon off;"]
