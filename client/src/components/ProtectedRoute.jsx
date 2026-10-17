import React from 'react'
import { Navigate, Outlet } from 'react-router-dom';
import Cookies from 'js-cookie';

const ProtectedRoute = () => {
    const token = Cookies.get('token');
  return (
      <div>
      {token ? <Outlet /> : <Navigate to="/login" />}
    </div>
  )
}

export default ProtectedRoute;
