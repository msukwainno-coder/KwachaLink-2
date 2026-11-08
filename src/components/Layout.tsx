import { Link, NavLink, Outlet, useNavigate } from 'react-router-dom';
import { ArrowUpRight, Bell, Menu, UserCircle, X } from 'lucide-react';
import { useEffect, useState } from 'react';
import { supabase } from '../lib/supabase';

export function Layout() {
  const [user, setUser] = useState<any>(null);
  const [menuOpen, setMenuOpen] = useState(false);
  const navigate = useNavigate();
  useEffect(() => {
    if (!supabase) return;
    supabase.auth.getUser().then(({data}) => setUser(data.user));
    const {data:{subscription}} = supabase.auth.onAuthStateChange((_event, session) => setUser(session?.user ?? null));
    return () => subscription.unsubscribe();
  }, []);
  async function logout() { if (supabase) await supabase.auth.signOut(); setMenuOpen(false); navigate('/'); }
  const nav = <><NavLink to="/forex">Forex</NavLink><NavLink to="/trade">International Trade</NavLink><NavLink to="/about">About</NavLink>{user ? <><NavLink to="/dashboard">Dashboard</NavLink><button className="nav-text-button" onClick={logout}>Sign out</button></> : <><NavLink to="/login">Log in</NavLink><Link className="nav-join" to="/register">Join KwachaLink <ArrowUpRight size={15}/></Link></>}</>;
  return <><header className="header"><div className="nav-shell"><Link to="/" className="brand"><span className="brand-symbol"><i/><i/></span><span>Kwacha<span className="brand-accent">Link</span><small>CONNECT. TRADE. GROW.</small></span></Link><nav className="desktop-nav">{nav}</nav><button className="mobile-menu" aria-label="Toggle menu" onClick={()=>setMenuOpen(!menuOpen)}>{menuOpen?<X/>:<Menu/>}</button></div>{menuOpen&&<nav className="mobile-nav" onClick={()=>setMenuOpen(false)}>{nav}</nav>}</header><main><Outlet/></main><footer className="footer"><div className="footer-inner"><div><Link to="/" className="brand footer-brand"><span className="brand-symbol"><i/><i/></span><span>Kwacha<span className="brand-accent">Link</span><small>CONNECT. TRADE. GROW.</small></span></Link><p>Connecting people and businesses to opportunities across borders.</p></div><div><strong>Marketplaces</strong><Link to="/forex">Forex connections</Link><Link to="/trade">International trade</Link></div><div><strong>Platform</strong><Link to="/about">About us</Link><Link to="/dashboard">Member dashboard</Link><Link to="/membership">Membership</Link></div><div><strong>Important</strong><span>KwachaLink is a connection platform, not a bank, payment processor or escrow service.</span></div></div><div className="copyright">© {new Date().getFullYear()} KwachaLink. All rights reserved.</div></footer></>;
}
