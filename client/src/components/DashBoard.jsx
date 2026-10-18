import React, { useState, useEffect } from 'react';
import api from '../api';
import { Trash2, Link, ExternalLink, Copy } from 'lucide-react';

const DashBoard = () => {
    const [urlInput, setUrlInput] = useState('');
    const [urls, setUrls] = useState([]);
    const [error, setError] = useState('');

    const handleCreateShortUrl = () => {
        if (!urlInput) {
            return;
        }


        
        api.post('/url/create', { Url: urlInput })
            .then((res) => {
                setUrlInput('');
                setError('');
                getAllUrls();
            })
            .catch((error) => {
                setError(error.response?.data?.message || 'Could not shorten this URL');
            });
    };

    useEffect(() => {
        getAllUrls();
    }, []);

    const getAllUrls = () => {
        api.get('/url/allUrls')
            .then((res) => {
                setUrls(res.data.urls);
            })
            .catch((error) => {
                console.log(error);
            });
    };

    const handleDelete = (shortId) => {
        api.delete(`/url/delete/${shortId}`)
            .then(() => {
                getAllUrls();
            })
            .catch((error) => {
                console.log(error);
            });
    };

    const handleCopy = (shortId) => {
        const fullUrl = `${window.location.origin}/r/${shortId}`;
        navigator.clipboard.writeText(fullUrl);
    };

    const handleShortLinkClick = (shortId) => {
        window.open(`/r/${shortId}`, '_blank');
    };

    return (
        <div className="min-h-screen bg-gray-50 py-12 px-4 sm:px-6 lg:px-8">
            <div className="max-w-4xl mx-auto">
                <div className="bg-white rounded-2xl shadow-xl p-8">
                    <div className="flex items-center justify-center mb-8">
                        <Link className="w-8 h-8 text-blue-600 mr-2" />
                        <h1 className="text-4xl font-bold text-gray-900">URL Shortener</h1>
                    </div>

                    <div className="mb-8">
                        <div className="flex gap-4">
                            <input
                                value={urlInput}
                                onChange={(e) => setUrlInput(e.target.value)}
                                placeholder="Enter your long URL here..."
                                className="flex-1 p-4 border border-gray-200 rounded-xl focus:ring-2 focus:ring-blue-500 focus:border-transparent transition-all duration-200 bg-gray-50"
                            />
                            <button
                                onClick={handleCreateShortUrl}
                                className="px-6 py-4 bg-blue-600 text-white rounded-xl hover:bg-blue-700 transition-colors duration-200 flex items-center gap-2 whitespace-nowrap"
                            >
                                <Link className="w-4 h-4" />
                                Shorten URL
                            </button>
                        </div>
                        {error && <p className="text-red-500 mt-2">{error}</p>}
                    </div>

                    <div className="space-y-6">
                        <h2 className="text-2xl font-semibold text-gray-900 flex items-center gap-2">
                            <Link className="w-5 h-5" />
                            Your Shortened URLs
                        </h2>

                        <div className="divide-y divide-gray-100">
                            {urls.map((url, index) => (
                                <div key={index} className="py-4 flex items-center justify-between group hover:bg-gray-50 rounded-lg transition-colors duration-200 px-4">
                                    <div className="flex-1 min-w-0 mr-4">
                                        <div className="flex items-center gap-4 mb-1">
                                            <button
                                                onClick={() => handleShortLinkClick(url.shortUrl)}
                                                className="text-blue-600 hover:text-blue-800 font-medium flex items-center gap-2"
                                            >
                                                {url.shortUrl}
                                                <ExternalLink className="w-4 h-4" />
                                            </button>
                                            <button
                                                onClick={() => handleCopy(url.shortUrl)}
                                                className="text-gray-400 hover:text-gray-600"
                                                title="Copy to clipboard"
                                            >
                                                <Copy className="w-4 h-4" />
                                            </button>
                                        </div>
                                        <p className="text-gray-500 text-sm truncate">{url.redirectUrl}</p>
                                    </div>
                                    <button
                                        onClick={() => handleDelete(url.shortUrl)}
                                        className="p-2 text-gray-400 hover:text-red-600 transition-colors duration-200"
                                        title="Delete URL"
                                    >
                                        <Trash2 className="w-5 h-5" />
                                    </button>
                                </div>
                            ))}
                        </div>

                        {urls.length === 0 && (
                            <div className="text-center py-12 bg-gray-50 rounded-xl">
                                <Link className="w-12 h-12 text-gray-400 mx-auto mb-4" />
                                <p className="text-gray-500 text-lg">No shortened URLs yet. Create your first one!</p>
                            </div>
                        )}
                    </div>
                </div>
            </div>
        </div>
    );
};

export default DashBoard;
