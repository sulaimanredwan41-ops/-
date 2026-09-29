import './globals.css';
import { IBM_Plex_Sans_Arabic } from 'next/font/google';
const plex = IBM_Plex_Sans_Arabic({ subsets: ['arabic'], weight: ['400', '500', '700'], variable: '--font-plex' });
export const metadata = { title: 'أوامر التشغيل', manifest: '/manifest.json' };
export const viewport = { themeColor: '#1B1F2A' };
export default function RootLayout({ children }) {
  return (<html lang="ar" dir="rtl" className={plex.variable}><body>{children}</body></html>);
}
