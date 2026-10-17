import React, { useEffect } from 'react';
import api from '../api';
import { useParams } from 'react-router-dom';

const Link = () => {
    const { shortId } = useParams(); 

    useEffect(() => {
        const getUrl = async () => {
            try {
                api.get(`/url/get`, { params: { shortUrl: shortId } })
                    .then((res) => {
                        window.location.replace(res.data.url.redirectUrl);
                    })
                    .catch((error) => {
                        console.log(error);
                    });
                
            }
            catch {
                console.log("error");
            }
        };
        if(shortId){
            getUrl();
        }
        
    }, [shortId]);

    return (
        <div>
            {/* You can add a loading indicator here if desired */}
            <h2>Redirecting...</h2>
        </div>
    );
};

export default Link;
