import './globals.css';

export const metadata = { title: 'UVBench Store', description: 'Reference app for the 30-day capacity benchmark' };

export default function RootLayout({ children }) {
  return (
    <html lang="en">
      <body>
        <header className="top">
          <a href="/" className="brand">UVBench Store</a>
          <nav>
            <a href="/products">Products</a>
            <a href="/search?q=laptop">Search</a>
            <a href="/chat">Live chat</a>
            <a href="/assistant">AI assistant</a>
          </nav>
        </header>
        <main>{children}</main>
      </body>
    </html>
  );
}
