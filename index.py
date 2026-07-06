from app.main import app
from mangum import Mangum

lambda_handler = Mangum(app)