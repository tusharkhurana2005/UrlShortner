import axios from 'axios';
import Cookies from 'js-cookie';

// Same-origin by default: in Kubernetes the ingress routes /api to the API
// service, and in local dev the CRA dev server proxies /api (see "proxy" in
// package.json). No hard-coded hostnames, so one build works everywhere.
const api = axios.create({
    baseURL: process.env.REACT_APP_API_BASE_URL || '/api',
});

api.interceptors.request.use((config) => {
    const token = Cookies.get('token');
    if (token) {
        config.headers.Authorization = `Bearer ${token}`;
    }
    return config;
});

api.interceptors.response.use(
    (res) => res,
    (error) => {
        // Expired or invalid session on a protected call: back to login.
        if (error.response && error.response.status === 401 && Cookies.get('token')) {
            Cookies.remove('token');
            Cookies.remove('user_Id');
            window.location.href = '/login';
        }
        return Promise.reject(error);
    }
);

export default api;
