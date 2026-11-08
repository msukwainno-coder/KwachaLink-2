import React from 'react';
import ReactDOM from 'react-dom/client';
import { BrowserRouter, Route, Routes } from 'react-router-dom';
import { Layout } from './components/Layout';
import Home from './pages/Home';
import { AuthPage } from './pages/Auth';
import { ForexPage, TradePage } from './pages/Market';
import Dashboard from './pages/Dashboard';
import CreateListing from './pages/CreateListing';
import { About, Admin, Membership, NotFound, Profile } from './pages/Static';
import { isSupabaseConfigured } from './lib/supabase';
import './styles.css';
function App(){return <><Routes><Route element={<Layout/>}><Route index element={<Home/>}/><Route path="/forex" element={<ForexPage/>}/><Route path="/trade" element={<TradePage/>}/><Route path="/login" element={<AuthPage mode="login"/>}/><Route path="/register" element={<AuthPage mode="register"/>}/><Route path="/dashboard" element={<Dashboard/>}/><Route path="/create-listing" element={<CreateListing/>}/><Route path="/about" element={<About/>}/><Route path="/membership" element={<Membership/>}/><Route path="/profile" element={<Profile/>}/><Route path="/admin" element={<Admin/>}/><Route path="*" element={<NotFound/>}/></Route></Routes>{!isSupabaseConfigured&&<div className="config-banner">Supabase configuration required — live data is not available until .env is configured.</div>}</>}
ReactDOM.createRoot(document.getElementById('root')!).render(<React.StrictMode><BrowserRouter><App/></BrowserRouter></React.StrictMode>);
